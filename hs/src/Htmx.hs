{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Htmx
  ( hsx
  , pageShell
  , module Lucid
  ) where

import Htmx.QQ (hsx)
import Lucid

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
