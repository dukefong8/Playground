{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

-- | The htmx view prelude: the @hsx@ quasiquoter ('Htmx.QQ'), the parsed htmx
-- header types ('Htmx.Type'), the page shell every stack renders into, the
-- servant html content type, and Lucid re-exported. Views import this module
-- alone, never 'Htmx.QQ' or 'Htmx.Type' directly.
--
-- Rendering lives here too: a view stays 'Html ()', and 'htmlResponse' turns one
-- into a response, so @renderBS@ — the one Lucid name held back from the
-- re-export — is used only inside this module.
module Htmx.Prelude
  ( HTML
  , module Htmx.QQ
  , module Htmx.Type
  , pageShell
  , htmlResponse
  , viewResponse
  , module Lucid
  ) where

import Htmx.QQ
import Htmx.Type
import Lucid hiding (renderBS)
import Lucid qualified (renderBS)
import Network.HTTP.Media ((//), (/:))
import Network.HTTP.Types (Status, hContentType, status200)
import Network.Wai (Response, responseLBS)
import Servant.API

data HTML

instance Accept HTML where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender HTML (Html ()) where
  mimeRender _ = Lucid.renderBS

-- | An html response: the rendered view, with the content type the stacks
-- share. Views never render themselves — this is where 'Html ()' becomes bytes.
htmlResponse :: Status -> Html () -> Response
htmlResponse status body =
  responseLBS status [(hContentType, "text/html; charset=utf-8")] (Lucid.renderBS body)

-- | 'htmlResponse' with the status fixed to 200, for handlers that render a
-- view result ('Todo.Route.runView').
viewResponse :: (a -> Html ()) -> a -> Response
viewResponse renderHtml value =
  htmlResponse status200 (renderHtml value)

-- The scittle build is deliberately scittle-kitchen's rather than upstream's: the
-- datascript and dataspex bundles are compiled plugins that register themselves
-- into an $APP global only that build defines. Loaded next to upstream
-- scittle@0.8.33 they fail silently, surfacing later as
-- "Could not find namespace: datascript.core" at require time. All four bundles
-- come from one scittle-kitchen release (0.8.33-105 ↔ scittle 0.8.33), and the
-- plugin order is the manifest's :depends-on — dataspex reads datascript.
--
-- reagami is loaded from source, so it is the one script here that scittle
-- evaluates itself. Its ns form excludes a pile of clojure.core (doseq, for,
-- map, filter, vec, set, println ...) and scittle evaluates each @x-scittle@
-- script in the ns the previous one left current — which is why every such
-- script must declare its own ns (see static/todo_filter.cljs); a script
-- without one silently loses those vars at analysis time.
pageShell :: Html () -> Html () -> Html ()
pageShell customHead body = [hsx|
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="UTF-8">
      <script defer src="https://cdn.jsdelivr.net/npm/htmx.org@next/dist/htmax.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/scittle-kitchen@0.8.33-105/dist/scittle.js" type="application/javascript"></script>
      <script src="https://cdn.jsdelivr.net/npm/scittle-kitchen@0.8.33-105/dist/scittle.datascript.js" type="application/javascript"></script>
      <script src="https://cdn.jsdelivr.net/npm/scittle-kitchen@0.8.33-105/dist/scittle.dataspex.js" type="application/javascript"></script>
      <script>var SCITTLE_NREPL_WEBSOCKET_PORT = 3340;</script>
      <script src="https://cdn.jsdelivr.net/npm/scittle-kitchen@0.8.33-105/dist/scittle.nrepl.js" type="application/javascript"></script>
      <script src="https://raw.githubusercontent.com/borkdude/reagami/refs/heads/main/src/reagami/core.cljc" type="application/x-scittle"></script>
      {customHead}
    </head>
    <body>
      {body}
    </body>
  </html>
|]
