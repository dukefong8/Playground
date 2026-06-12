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
      <title>Todo Servant</title>
      <link href="https://unpkg.com/todomvc-app-css@2.4.1/index.css" rel="stylesheet">
      <script defer src="https://cdn.jsdelivr.net/npm/htmx.org@next"></script>
      <style>
        @keyframes duplicate-flash {
          0% {
            background: rgba(255, 208, 0, 0.45);
          }

          100% {
            background: transparent;
          }
        }

        .todo-list li.duplicate-flash {
          animation: duplicate-flash 0.9s ease;
        }
      </style>
    </head>
    <body>
      {body}
      <footer class="info">
        <p>Double-click to edit, Enter to add</p>
      </footer>
    </body>
  </html>
|]
