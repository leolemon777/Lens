fn main() {
    if std::env::args().any(|arg| arg == "--print-inventory") {
        lens_desktop_probe_lib::print_inventory();
        return;
    }
    lens_desktop_probe_lib::run();
}
