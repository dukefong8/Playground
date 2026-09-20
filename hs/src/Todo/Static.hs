{-# LANGUAGE OverloadedStrings #-}

-- | The todo filter's client script, contributed to the site's static
-- application ('Site.Static') rather than served by a route of its own.
module Todo.Static
  ( todoFilterAsset
  , assetSources
  , assetEntries
  ) where

import WaiAppStatic.Storage.Embedded (EmbeddableEntry (..))

-- | The script: its source under the project root and — since the site serves
-- that directory at @\/static@ — the path it is served at, which is how
-- 'Site.Static' keys the entry ('Site.Static.staticUrl' builds the URL the page
-- head loads).
todoFilterAsset :: FilePath
todoFilterAsset = "static/todo_filter.cljs"

-- | Registered through 'Site.Static' so an edit to the source recompiles the
-- embedding.
assetSources :: [FilePath]
assetSources = [todoFilterAsset]

-- | The script as an embedded entry. The empty etag means "no etag": clients
-- re-fetch every time, since a cached copy is always the wrong copy while the
-- file changes with every edit.
assetEntries :: IO [EmbeddableEntry]
assetEntries = do
  cljs <- readFileLBS todoFilterAsset
  pure
    [ EmbeddableEntry
        { eLocation = toText todoFilterAsset
        , eMimeType = "application/x-scittle"
        , eContent = Left ("", cljs)
        }
    ]
