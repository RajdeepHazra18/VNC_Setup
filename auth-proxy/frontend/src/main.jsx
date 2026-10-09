import React from "react";
import ReactDOM from "react-dom/client";
import LoginPage from "./LoginPage.jsx";
import WebcamPage from "./WebcamPage.jsx";

// The same built index.html is served at /login and /webcam; pick the page by URL.
const Page = window.location.pathname.startsWith("/webcam") ? WebcamPage : LoginPage;

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <Page />
  </React.StrictMode>
);
