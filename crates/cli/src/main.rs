use std::io::Read;

use sa_monopoly_application::bridge::{BridgeRequest, EngineBridge};

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let input = if args.len() > 1 {
        // Command provided as argument: read file or JSON string
        let path_or_json = &args[1];
        match std::fs::read_to_string(path_or_json) {
            Ok(content) => content,
            Err(_) => path_or_json.clone(), // treat as raw JSON string
        }
    } else {
        // Read from stdin (pipe)
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .expect("Failed to read stdin");
        buf
    };

    let input = input.trim().to_string();
    if input.is_empty() {
        eprintln!("sa-monopoly engine CLI");
        eprintln!("Usage: echo '<json>' | sa-monopoly-cli");
        eprintln!("   or: sa-monopoly-cli request.json");
        eprintln!("   or: sa-monopoly-cli < path/to/request.json");
        std::process::exit(1);
    }

    match EngineBridge::execute_json(&input) {
        Ok(output) => println!("{output}"),
        Err(err) => {
            eprintln!("Error: {err}");
            std::process::exit(1);
        }
    }
}
