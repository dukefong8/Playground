{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | The site's embedded static assets: one wai-app-static application, built at
-- compile time from what the sub-apps contribute, mounted by 'Site' under the
-- single @\/static@ prefix they share.
--
-- A sub-app contributes assets from its own module — today @Todo.Static@
-- exports the entries and their sources — and never adds a route of its own.
-- An entry is keyed by the URL path it is served at, so the key is the URL
-- minus the leading slash that 'staticUrl' adds back.
module Site.Static
  ( staticUrl
  , staticApp
  ) where

import Language.Haskell.TH.Syntax (addDependentFile)
import Network.Wai (Application)
import Network.Wai.Application.Static qualified as Static
import WaiAppStatic.Storage.Embedded (mkSettings)
import WaiAppStatic.Types (MaxAge (NoStore), StaticSettings, ssMaxAge)

import Todo.Static qualified as Todo

-- | The URL an embedded asset is served at, from the key it was contributed
-- under. Markup loads assets through this; nothing else spells the prefix.
staticUrl :: FilePath -> Text
staticUrl asset = "/" <> toText asset

-- | Every sub-app's assets, embedded once.
--
-- The splice belongs here rather than in the contributing modules: Template
-- Haskell's stage restriction lets a splice reference imported names only, so
-- the entries come from the app modules while the embedding — and the
-- @NoStore@ policy that goes with a compile-time copy — stay in one place.
staticSettings :: StaticSettings
staticSettings =
  ( $( do
        mapM_ addDependentFile Todo.assetSources
        mkSettings (concat <$> sequenceA [Todo.assetEntries])
     )
      { ssMaxAge = NoStore }
  )

-- | The site's static application. 'Site' mounts it under @\/static@; wai-app-
-- static looks entries up by request path, which is why a key carries the
-- prefix.
staticApp :: Application
staticApp = Static.staticApp staticSettings
