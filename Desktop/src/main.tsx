import { createRoot } from "react-dom/client";
import App from "./app/App";
import "../styles/probe.css";

if (new URLSearchParams(window.location.search).get("window") === "overlay") {
  document.documentElement.classList.add("overlay-window");
}
const kind = new URLSearchParams(window.location.search).get("window");
if (kind === "island" || kind === "quick-access" || kind === "pin" || kind === "record-bar") {
  document.documentElement.classList.add("overlay-window");
  document.documentElement.classList.add(`${kind}-window`);
}

document.title = "Lens";

createRoot(document.getElementById("root")!).render(<App />);
