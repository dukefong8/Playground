{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

module Http
  ( HTML
  , pageShell
  ) where

import Htmx
import Network.HTTP.Media ((//), (/:))
import Servant.API

data HTML

instance Accept HTML where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender HTML (Html ()) where
  mimeRender _ = renderBS

pageShell :: Html () -> Html ()
pageShell body = [hsx|
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Premium Todo Dashboard</title>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/tyrell-components@1.0.0-RC10/css/tyrell.css">
      <style>
        * {
          font-family: 'Outfit', sans-serif;
          box-sizing: border-box;
        }
        body {
          background: radial-gradient(circle at top left, #1e1b4b, #0f172a);
          color: #f8fafc;
          min-height: 100vh;
          display: flex;
          align-items: center;
          justify-content: center;
          margin: 0;
          padding: 20px;
        }
        main.todo-shell {
          width: 100%;
          display: flex;
          justify-content: center;
        }
        .todo-highlight {
          animation: todo-flash 0.9s ease-out;
        }
        @keyframes todo-flash {
          0% { background-color: rgba(99, 102, 241, 0.4); }
          100% { background-color: transparent; }
        }
        #add-form {
          margin: 0 0 20px 0;
          position: relative;
        }
        .todo-submit {
          display: none;
        }
        .todoapp {
          background: rgba(30, 41, 59, 0.6);
          backdrop-filter: blur(16px);
          -webkit-backdrop-filter: blur(16px);
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 24px;
          box-shadow: 0 20px 50px rgba(0, 0, 0, 0.4);
          width: 100%;
          max-width: 550px;
          padding: 32px;
          box-sizing: border-box;
          transition: transform 0.3s ease, border-color 0.3s ease;
        }
        .todoapp:hover {
          transform: translateY(-2px);
          border-color: rgba(255, 255, 255, 0.12);
        }
        .header h1 {
          font-weight: 800;
          font-size: 3.5rem;
          text-align: center;
          margin: 0 0 28px 0;
          background: linear-gradient(135deg, #c084fc 0%, #6366f1 100%);
          -webkit-background-clip: text;
          -webkit-text-fill-color: transparent;
          letter-spacing: -0.05em;
          text-transform: uppercase;
        }
        .todo-list {
          list-style: none;
          padding: 0;
          margin: 0 0 24px 0;
        }
        .todo-list li {
          background: rgba(255, 255, 255, 0.02);
          border: 1px solid rgba(255, 255, 255, 0.04);
          border-radius: 14px;
          margin-bottom: 12px;
          padding: 14px 18px;
          display: flex;
          align-items: center;
          position: relative;
          transition: all 0.2s ease;
        }
        .todo-list li:hover {
          background: rgba(255, 255, 255, 0.05);
          border-color: rgba(255, 255, 255, 0.1);
          transform: scale(1.005);
        }
        .todo-list li .view {
          display: flex;
          align-items: center;
          width: 100%;
        }
        .todo-list li label {
          color: #e2e8f0;
          font-size: 16px;
          font-weight: 400;
          padding: 8px 12px 8px 38px;
          display: block;
          width: 100%;
          cursor: pointer;
          transition: color 0.2s ease;
          word-break: break-all;
        }
        .todo-list li.completed label {
          color: #64748b;
          text-decoration: line-through;
        }
        .todo-list li ty-button.destroy {
          opacity: 0;
          transition: opacity 0.2s ease !important;
          position: absolute;
          right: 12px;
          top: 50%;
          transform: translateY(-50%);
          width: 28px;
          height: 28px;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .todo-list li:hover ty-button.destroy {
          opacity: 1;
        }
        .todo-list li .toggle {
          -webkit-appearance: none;
          appearance: none;
          border: none;
          bottom: 0;
          cursor: pointer;
          height: auto;
          margin: auto 0;
          opacity: 0;
          position: absolute;
          text-align: center;
          top: 0;
          width: 32px;
          z-index: 2;
        }
        .todo-list li .toggle + label {
          background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 30 30"><circle cx="15" cy="15" r="13" fill="none" stroke="%23475569" stroke-width="2"/></svg>');
          background-position: left center;
          background-repeat: no-repeat;
          background-size: 24px 24px;
          padding-left: 36px;
        }
        .todo-list li .toggle[checked] + label {
          background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 30 30"><circle cx="15" cy="15" r="13" fill="%236366f1" stroke="%236366f1" stroke-width="2"/><path fill="none" stroke="%23ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="M9 15l4 4 8-8"/></svg>');
        }
        .todoapp ty-input.edit {
          display: block;
          margin: 0;
          padding: 0;
          width: 100%;
        }
        .todo-list li.editing {
          padding: 6px 12px;
        }
        .todo-list li.editing .todo-edit-form {
          width: 100%;
          display: flex;
          align-items: center;
        }
        .footer {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 20px 4px 0 4px;
          border-top: 1px solid rgba(255, 255, 255, 0.08);
          color: #64748b;
          font-size: 14px;
        }
        .todo-count strong {
          color: #f8fafc;
          font-weight: 600;
        }
        .filters {
          display: flex;
          list-style: none;
          padding: 0;
          margin: 0;
          gap: 6px;
        }
        .filters li a {
          color: #94a3b8;
          text-decoration: none;
          padding: 6px 12px;
          border-radius: 8px;
          transition: all 0.2s ease;
          border: 1px solid transparent;
          font-weight: 500;
        }
        .filters li a:hover {
          color: #f8fafc;
          background: rgba(255, 255, 255, 0.05);
        }
        .filters li a.selected {
          color: #ffffff;
          background: #6366f1;
          border-color: rgba(99, 102, 241, 0.4);
          box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3);
        }
        .todoapp ty-button.clear-completed {
          color: #ef4444 !important;
          transition: all 0.2s ease !important;
          cursor: pointer;
        }
        .todoapp ty-button.clear-completed:hover {
          opacity: 0.85;
          text-decoration: none !important;
        }
        .info-hint {
          text-align: center;
          margin: 20px 0 0 0;
          color: #334155;
          font-size: 12px;
          font-weight: 400;
        }
      </style>
      <script type="module" src="https://cdn.jsdelivr.net/npm/tyrell-components@1.0.0-RC10/dist/tyrell.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/htmx.org@4.0.0-beta4/dist/htmx.min.js" integrity="sha384-aWZK1NtOs/aWb/+YZdTM8q2JkWEshlMc9mgZ189numT9bwFhyAyYEoO4nO/2dTXt" crossorigin="anonymous"></script>
      <script>
        function styleTodoTyrellControls(root) {
          const css = `
            :host {
              font-family: 'Outfit', sans-serif;
            }
            :host(#todo-input) .input-wrapper,
            :host(.edit) .input-wrapper {
              background: rgba(15, 23, 42, 0.4) !important;
              border: 1px solid rgba(255, 255, 255, 0.08) !important;
              border-radius: 12px !important;
              padding: 12px 18px !important;
              box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2) !important;
              transition: all 0.3s ease !important;
              height: 52px !important;
            }
            :host(#todo-input:focus-within) .input-wrapper,
            :host(.edit:focus-within) .input-wrapper {
              border-color: #6366f1 !important;
              box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.3), inset 0 2px 4px rgba(0, 0, 0, 0.2) !important;
            }
            :host(#todo-input) input,
            :host(.edit) input {
              background: transparent !important;
              border: 0 !important;
              color: #f8fafc !important;
              font-family: 'Outfit', sans-serif !important;
              font-size: 16px !important;
              font-weight: 400 !important;
              outline: none !important;
              padding: 0 !important;
              width: 100%;
              height: 100% !important;
            }
            :host(#todo-input) input::placeholder {
              color: #475569 !important;
              font-style: normal !important;
            }
            :host(.edit) .input-wrapper {
              background: rgba(15, 23, 42, 0.6) !important;
              height: 44px !important;
              padding: 8px 14px !important;
            }
            :host(.destroy) button,
            :host(.clear-completed) button {
              background: transparent !important;
              border: 0 !important;
              border-radius: 0 !important;
              box-shadow: none !important;
              color: inherit;
              font: inherit;
              height: auto;
              min-width: 0;
              padding: 0 !important;
            }
            :host(.clear-completed) button {
              background: rgba(239, 68, 68, 0.1) !important;
              border: 1px solid rgba(239, 68, 68, 0.2) !important;
              border-radius: 8px !important;
              color: #fca5a5 !important;
              padding: 6px 12px !important;
              cursor: pointer !important;
              transition: all 0.2s ease !important;
              font-weight: 500 !important;
            }
            :host(.clear-completed) button:hover {
              background: rgba(239, 68, 68, 0.2) !important;
              color: #ffffff !important;
            }
            :host(.destroy) button,
            :host(.destroy) button.neutral.md.solid {
              background: transparent !important;
              border: 0 !important;
              border-radius: 50% !important;
              box-shadow: none !important;
              color: #64748b !important;
              cursor: pointer !important;
              display: flex !important;
              align-items: center !important;
              justify-content: center !important;
              font-size: 22px !important;
              font-weight: 300 !important;
              height: 28px !important;
              line-height: 1 !important;
              min-width: 0 !important;
              padding: 0 !important;
              transition: color 0.2s ease, background 0.2s ease !important;
              width: 28px !important;
            }
            :host(.destroy) button:hover,
            :host(.destroy) button.neutral.md.solid:hover {
              background: rgba(239, 68, 68, 0.15) !important;
              color: #ef4444 !important;
            }
            :host(.destroy) button *,
            :host(.destroy) slot {
              display: none !important;
            }
            :host(.destroy) button::after {
              content: "×" !important;
              display: block !important;
              font-size: 22px !important;
              line-height: 1 !important;
            }
          `;
          (root || document).querySelectorAll(".todoapp ty-input, .todoapp ty-button").forEach(function (el) {
            if (!el.shadowRoot || el.shadowRoot.querySelector("style[data-todo-style]")) return;
            const style = document.createElement("style");
            style.setAttribute("data-todo-style", "");
            style.textContent = css;
            el.shadowRoot.appendChild(style);
          });
        }
        customElements.whenDefined("ty-input").then(function () { styleTodoTyrellControls(document); });
        customElements.whenDefined("ty-button").then(function () { styleTodoTyrellControls(document); });
        document.addEventListener("htmx:afterSwap", function () { styleTodoTyrellControls(document); });
      </script>
    </head>
    <body>
      <main class="todo-shell">
        {body}
      </main>
    </body>
  </html>
|]
