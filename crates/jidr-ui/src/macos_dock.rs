//! Dock menu and orderly Quit for Winit's existing application delegate.

use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
use objc2::{ffi, sel};
use objc2_app_kit::{NSApplication, NSMenu, NSMenuItem, NSWindowButton};
use objc2_foundation::{MainThreadMarker, NSPoint};
use std::cell::RefCell;
use std::panic::{AssertUnwindSafe, catch_unwind};

thread_local! {
    static CONTROL_ORIGINS: RefCell<Vec<(NSWindowButton, NSPoint)>> = const { RefCell::new(Vec::new()) };
}

/// Align the native window controls with the custom main title bar.
pub fn align_main_window_controls() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    for window in NSApplication::sharedApplication(mtm).windows().iter() {
        if window.title().to_string() != "Jidr" {
            continue;
        }
        let kinds = [
            NSWindowButton::CloseButton,
            NSWindowButton::MiniaturizeButton,
            NSWindowButton::ZoomButton,
        ];
        CONTROL_ORIGINS.with(|origins| {
            if !origins.borrow().is_empty() {
                return;
            }
            let mut positions = Vec::new();
            for kind in kinds {
                let Some(button) = window.standardWindowButton(kind) else {
                    return;
                };
                // SAFETY: this button is owned by the live main window and
                // accessed on the main thread; retain its superview locally.
                let Some(parent) = (unsafe { button.superview() }) else {
                    return;
                };
                let before = button.frame().origin;
                let mut origin = before;
                origin.x += 5.0;
                origin.y += if parent.isFlipped() { 6.0 } else { -6.0 };
                tracing::info!(
                    ?kind,
                    ?before,
                    ?origin,
                    flipped = parent.isFlipped(),
                    "positioning native window control"
                );
                positions.push((kind, origin));
            }
            tracing::info!(?positions, "aligning main window controls");
            *origins.borrow_mut() = positions;
        });
        for (kind, origin) in CONTROL_ORIGINS.with(|origins| origins.borrow().clone()) {
            let Some(button) = window.standardWindowButton(kind) else {
                continue;
            };
            if button.frame().origin != origin {
                button.setFrameOrigin(origin);
                tracing::info!(?kind, actual = ?button.frame().origin, "applied native window control position");
            }
        }
        break;
    }
}

fn include_window(title: &str, visible: bool, minimized: bool) -> bool {
    (visible || minimized) && title.ends_with(" — Jidr")
}

/// Winit's delegate remains untouched if a future version already implements
/// these selectors. All calls and objects are confined to the main thread.
pub fn install() {
    let Some(class) = AnyClass::get(c"WinitApplicationDelegate") else {
        tracing::warn!("Can't install Dock menu: winit application delegate not found");
        return;
    };
    let dock_selector = sel!(applicationDockMenu:);
    let raise_selector = sel!(jidrRaiseDockWindow:);
    install_quit_handler(class);
    if class.instance_method(dock_selector).is_some() {
        tracing::warn!("Can't install Dock menu: application delegate already implements it");
        return;
    }
    // SAFETY: Objective-C runtime methods use these exact object argument and
    // return encodings. The class is winit's process-lifetime delegate class;
    // class_addMethod never replaces an existing implementation.
    unsafe {
        let class_ptr = (class as *const AnyClass).cast_mut();
        let raise: Imp = std::mem::transmute::<
            unsafe extern "C-unwind" fn(&AnyObject, Sel, &NSMenuItem),
            Imp,
        >(raise_window);
        if !ffi::class_addMethod(class_ptr, raise_selector, raise, c"v@:@".as_ptr()).as_bool() {
            tracing::warn!("Can't install Dock menu: raise action already exists");
            return;
        }
        let dock: Imp = std::mem::transmute::<
            unsafe extern "C-unwind" fn(&AnyObject, Sel, &NSApplication) -> *mut NSMenu,
            Imp,
        >(dock_menu);
        if !ffi::class_addMethod(class_ptr, dock_selector, dock, c"@@:@".as_ptr()).as_bool() {
            tracing::warn!("Can't install Dock menu callback");
        }
    }
}

fn install_quit_handler(class: &AnyClass) {
    let selector = sel!(applicationShouldTerminate:);
    if class.instance_method(selector).is_some() {
        tracing::error!(
            "Can't install orderly Quit: application delegate already implements termination"
        );
        return;
    }
    // SAFETY: AppKit calls this delegate on the main thread with one NSApp
    // argument and an NSUInteger return value (NSApplicationTerminateReply).
    unsafe {
        let implementation: Imp = std::mem::transmute::<
            unsafe extern "C-unwind" fn(&AnyObject, Sel, &NSApplication) -> usize,
            Imp,
        >(should_terminate);
        if !ffi::class_addMethod(
            (class as *const AnyClass).cast_mut(),
            selector,
            implementation,
            c"Q@:@".as_ptr(),
        )
        .as_bool()
        {
            tracing::error!("Can't install orderly Quit callback");
        }
    }
}

unsafe extern "C-unwind" fn should_terminate(
    _delegate: &AnyObject,
    _selector: Sel,
    _app: &NSApplication,
) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        if crate::app::begin_native_quit() {
            2
        } else {
            0
        }
    }))
    .unwrap_or(0)
}

/// Completes a pending AppKit termination request on the main thread.
pub fn reply_to_quit(should_terminate: bool) {
    if let Some(mtm) = MainThreadMarker::new() {
        NSApplication::sharedApplication(mtm).replyToApplicationShouldTerminate(should_terminate);
    }
}

unsafe extern "C-unwind" fn dock_menu(
    delegate: &AnyObject,
    _selector: Sel,
    app: &NSApplication,
) -> *mut NSMenu {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(mtm) = MainThreadMarker::new() else {
            return std::ptr::null_mut();
        };
        let menu = NSMenu::new(mtm);
        for window in app.windows().iter() {
            let title = window.title();
            if !include_window(
                &title.to_string(),
                window.isVisible(),
                window.isMiniaturized(),
            ) {
                continue;
            }
            let item = NSMenuItem::new(mtm);
            item.setTitle(&title);
            item.setTag(window.windowNumber());
            // SAFETY: the delegate has the action installed by `install`, and
            // outlives the menu; NSMenuItem keeps its target weakly.
            unsafe {
                item.setTarget(Some(delegate));
                item.setAction(Some(sel!(jidrRaiseDockWindow:)));
            }
            menu.addItem(&item);
        }
        if menu.numberOfItems() == 0 {
            return std::ptr::null_mut();
        }
        Retained::autorelease_return(menu)
    }))
    .unwrap_or(std::ptr::null_mut())
}

unsafe extern "C-unwind" fn raise_window(_delegate: &AnyObject, _selector: Sel, item: &NSMenuItem) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let app = NSApplication::sharedApplication(mtm);
        if let Some(window) = app
            .windows()
            .iter()
            .find(|w| w.windowNumber() == item.tag())
        {
            if window.isMiniaturized() {
                window.deminiaturize(None);
            }
            // The preview supports macOS 13, and this user-initiated Dock
            // action needs to activate even when another app is in front.
            #[allow(deprecated)]
            app.activateIgnoringOtherApps(true);
            window.makeKeyAndOrderFront(None);
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::include_window;
    #[test]
    fn dock_lists_only_open_or_minimized_game_windows() {
        assert!(include_window("Phone 6.1 FHD+ — Jidr", true, false));
        assert!(include_window("Phone 6.1 FHD+ — Jidr", false, true));
        assert!(!include_window("Phone 6.1 FHD+ — Jidr", false, false));
        assert!(!include_window("Jidr", true, false));
    }
}
