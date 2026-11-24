//! Merges NotchAgent's Claude Code command hooks into the user's settings.

use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const WIRING: &[(&str, bool, &str)] = &[
    ("SessionStart", false, "session_start"),
    ("UserPromptSubmit", false, "running"),
    ("PreToolUse", true, "running"),
    ("PostToolUse", true, "running"),
    ("Notification", false, "attention"),
    ("Stop", false, "done"),
    ("SessionEnd", false, "session_end"),
];

fn settings_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".claude").join("settings.json"))
}

fn is_ours(handler: &Value) -> bool {
    let Some(command) = handler["command"].as_str() else {
        return false;
    };
    let command = command.trim_start();
    let exe = if let Some(quoted) = command.strip_prefix('"') {
        quoted.split('"').next()
    } else {
        command.split_whitespace().next()
    };
    let name = exe.and_then(|exe| exe.rsplit(['\\', '/']).next());
    name.is_some_and(|name| {
        ["codenotch-hook.exe", "eatbean-hook.exe", "pacman-hook.exe"]
            .iter()
            .any(|expected| name.eq_ignore_ascii_case(expected))
    })
}

fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => {
            fs::read(path).map(Some).map_err(|error| error.to_string())
        }
        Ok(_) => Err("Claude settings must be a regular file".into()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

fn load(original: Option<&[u8]>) -> Result<Value, String> {
    let Some(original) = original else {
        return Ok(json!({}));
    };
    let value: Value = serde_json::from_slice(original)
        .map_err(|error| format!("Invalid Claude settings: {error}"))?;
    if !value.is_object() || value.get("hooks").is_some_and(|hooks| !hooks.is_object()) {
        return Err("Claude settings and hooks must be JSON objects".into());
    }
    if let Some(hooks) = value.get("hooks").and_then(Value::as_object) {
        for (event, entries) in hooks {
            let valid = entries.as_array().is_some_and(|entries| {
                entries.iter().all(|entry| {
                    entry["hooks"]
                        .as_array()
                        .is_some_and(|handlers| handlers.iter().all(Value::is_object))
                })
            });
            if !valid {
                return Err(format!("Invalid Claude hook configuration for {event}"));
            }
        }
    }
    Ok(value)
}

fn create_file(path: &Path, content: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| error.to_string())?;
    if let Err(error) = file.write_all(content).and_then(|_| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(error.to_string());
    }
    Ok(())
}

fn unique_suffix() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let index = NEXT.fetch_add(1, Ordering::Relaxed);
    format!("{}-{nanos}-{index}", std::process::id())
}

fn write_settings(path: &Path, original: Option<&[u8]>, root: &Value) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|error| error.to_string())?;
    }
    let suffix = unique_suffix();
    if let Some(original) = original {
        let backup = path.with_extension(format!("json.codenotch-bak-{suffix}"));
        create_file(&backup, original)
            .map_err(|error| format!("Could not back up Claude settings: {error}"))?;
        if fs::read(&backup).ok().as_deref() != Some(original) {
            return Err("Could not verify the Claude settings backup".into());
        }
    }
    let temporary = path.with_extension(format!("json.codenotch-tmp-{suffix}"));
    let data = serde_json::to_vec_pretty(root).map_err(|error| error.to_string())?;
    create_file(&temporary, &data)?;
    let result = (|| {
        if read(path)?.as_deref() != original {
            return Err("Claude settings changed during the hook update. Try again.".into());
        }
        fs::rename(&temporary, path).map_err(|error| error.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn remove_owned(root: &mut Value) -> usize {
    let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) else {
        return 0;
    };
    let mut removed = 0;
    for entries in hooks.values_mut().filter_map(Value::as_array_mut) {
        entries.retain_mut(|entry| {
            let handlers = entry["hooks"].as_array_mut().expect("validated hook group");
            let count = handlers.len();
            handlers.retain(|handler| !is_ours(handler));
            let changed = count - handlers.len();
            removed += changed;
            changed == 0 || !handlers.is_empty()
        });
    }
    removed
}

pub fn is_installed() -> bool {
    settings_path()
        .and_then(|path| read(&path).ok().flatten())
        .and_then(|original| load(Some(&original)).ok())
        .is_some_and(|mut root| remove_owned(&mut root) > 0)
}

pub fn install() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let hook = executable
        .parent()
        .ok_or("cannot locate the program directory")?
        .join("codenotch-hook.exe");
    if !hook.is_file() {
        return Err(format!("missing {}", hook.display()));
    }
    install_at(&path, &hook)
}

fn install_at(path: &Path, hook: &Path) -> Result<String, String> {
    let original = read(path)?;
    let mut root = load(original.as_deref())?;
    let before = root.clone();
    remove_owned(&mut root);
    if root.get("hooks").is_none() {
        root["hooks"] = json!({});
    }
    for (event, needs_matcher, internal) in WIRING {
        let command = format!("\"{}\" {}", hook.display(), internal);
        let mut entry =
            json!({ "hooks": [{ "type": "command", "command": command, "timeout": 5 }] });
        if *needs_matcher {
            entry["matcher"] = json!("*");
        }
        if root["hooks"].get(*event).is_none() {
            root["hooks"][*event] = json!([]);
        }
        root["hooks"][*event]
            .as_array_mut()
            .expect("validated event list")
            .push(entry);
    }
    if root != before {
        write_settings(path, original.as_deref(), &root)?;
    }
    Ok(format!(
        "Installed NotchAgent hooks for {} events",
        WIRING.len()
    ))
}

pub fn uninstall() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    let original = read(&path)?;
    let mut root = load(original.as_deref())?;
    let removed = remove_owned(&mut root);
    if removed > 0 {
        write_settings(&path, original.as_deref(), &root)?;
    }
    Ok(format!("Removed {removed} NotchAgent hook(s)"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(action: impl FnOnce(&Path)) {
        let directory =
            std::env::temp_dir().join(format!("notch-claude-hooks-{}", unique_suffix()));
        fs::create_dir(&directory).unwrap();
        action(&directory.join("settings.json"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn malformed_settings_are_preserved() {
        fixture(|path| {
            let original = br#"{"hooks": invalid}"#;
            fs::write(path, original).unwrap();
            assert!(install_at(path, Path::new("codenotch-hook.exe")).is_err());
            assert_eq!(fs::read(path).unwrap(), original);
        });
    }

    #[test]
    fn install_keeps_other_handlers_in_a_mixed_group_and_backs_up_bytes() {
        fixture(|path| {
            let original = br#"{"hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"\"C:\\Old\\codenotch-hook.exe\" done"},{"type":"command","command":"echo codenotch-hook.exe"}]}]},"other":true}"#;
            fs::write(path, original).unwrap();
            install_at(path, Path::new("C:\\New\\codenotch-hook.exe")).unwrap();
            let root = load(read(path).unwrap().as_deref()).unwrap();
            assert_eq!(root["other"], true);
            assert_eq!(root["hooks"]["Stop"][0]["matcher"], "keep");
            assert_eq!(
                root["hooks"]["Stop"][0]["hooks"][0]["command"],
                "echo codenotch-hook.exe"
            );
            let backups: Vec<_> = fs::read_dir(path.parent().unwrap())
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .contains("codenotch-bak")
                })
                .collect();
            assert_eq!(backups.len(), 1);
            assert_eq!(fs::read(backups[0].path()).unwrap(), original);
        });
    }

    #[test]
    fn a_concurrent_settings_edit_is_preserved() {
        fixture(|path| {
            let older = br#"{"original":true}"#;
            let current = br#"{"edited":true}"#;
            fs::write(path, current).unwrap();
            assert!(write_settings(path, Some(older), &json!({"hooks":{}})).is_err());
            assert_eq!(fs::read(path).unwrap(), current);
        });
    }
}
