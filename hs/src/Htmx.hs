{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Htmx
  ( HTML
  , hsx
  , pageShell
  , module Lucid
  ) where

import Htmx.QQ (hsx)
import Lucid
import Network.HTTP.Media ((//), (/:))
import Servant.API

data HTML

instance Accept HTML where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender HTML (Html ()) where
  mimeRender _ = renderBS

pageShell :: Html () -> Html () -> Html ()
pageShell customHead body = [hsx|
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="UTF-8">
      <script defer src="https://cdn.jsdelivr.net/npm/htmx.org@next"></script>
      {customHead}
    </head>
    <body>
      {body}
    </body>
  </html>
|]
