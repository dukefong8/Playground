{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Parsed htmx header types (htmx v4).
--
-- Sources:
--
-- * <https://four.htmx.org/reference>
-- * per-header pages, e.g. <https://four.htmx.org/reference/headers/HX-Trigger>
--
-- Design follows /Parse, don't validate/
-- (<https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/>):
-- every header is parsed __once__, at the system boundary, into a type whose
-- values are all meaningful. Smart constructors ('mkCssSelector',
-- 'parseElementRef', …) are total: anything htmx does not document is
-- rejected with a 'Text' error instead of admitted as a bare 'Text' and
-- re-checked by every consumer.
--
-- Composition:
--
-- * @servant@: request headers compose via 'Web.HttpApiData.FromHttpApiData'
--   (e.g. @'Servant.API.Header.Header' "HX-Request" 'IsHtmxRequest'@),
--   response headers via 'Web.HttpApiData.ToHttpApiData'
--   (e.g. @'Servant.API.ResponseHeaders.Headers'
--   '['Servant.API.Header.Header' "HX-Trigger" 'TriggerEvents']@).
-- * @wai@: 'lookupParsedHeader' reads a typed request header and
--   'withResponseHeader' sets a typed response header.
--
-- Notes on v4 coverage:
--
-- * The reference documents 16 headers; v1\/v2 extras such as @HX-Prompt@,
--   @HX-Trigger-Name@, @HX-Trigger-After-Swap@ and @HX-Trigger-After-Settle@
--   are gone. Request-side trigger identity is 'HX-Source' ('ElementRef');
--   'HX-Trigger' is response-only and fires after the swap completes.
module Htmx.Type
  ( -- * Header names
    hHXBoosted
  , hHXCurrentUrl
  , hHXHistoryRestoreRequest
  , hHXLocation
  , hHXPushUrl
  , hHXRedirect
  , hHXRefresh
  , hHXReplaceUrl
  , hHXRequest
  , hHXRequestType
  , hHXReselect
  , hHXReswap
  , hHXRetarget
  , hHXSource
  , hHXTarget
  , hHXTrigger
    -- * Shared shapes
  , CssSelector (..)
  , mkCssSelector
  , ElementRef (..)
  , parseElementRef
  , HistoryUrl (..)
  , parseHistoryUrl
    -- * Request headers
  , IsHtmxRequest (..)
  , RequestType (..)
  , parseRequestType
  , IsBoosted (..)
  , CurrentUrl (..)
  , mkCurrentUrl
  , IsHistoryRestore (..)
    -- * Response headers
  , Location (..)
  , LocationContext (..)
  , parseLocation
  , RedirectUrl (..)
  , mkRedirectUrl
  , RefreshPage (..)
  , SwapSpec (..)
  , mkSwapSpec
  , EventName (..)
  , mkEventName
  , TriggerEvent (..)
  , TriggerEvents (..)
  , parseTriggerEvents
    -- * WAI boundary helpers
  , lookupParsedHeader
  , withResponseHeader
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isSpace)
import Data.List (lookup)
import Data.Text qualified as T
import Network.HTTP.Types.Header (HeaderName)
import Network.Wai (Request, Response, mapResponseHeaders, requestHeaders)
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

-- * Header names

hHXBoosted :: HeaderName
hHXBoosted = "HX-Boosted"

hHXCurrentUrl :: HeaderName
hHXCurrentUrl = "HX-Current-URL"

hHXHistoryRestoreRequest :: HeaderName
hHXHistoryRestoreRequest = "HX-History-Restore-Request"

hHXLocation :: HeaderName
hHXLocation = "HX-Location"

hHXPushUrl :: HeaderName
hHXPushUrl = "HX-Push-Url"

hHXRedirect :: HeaderName
hHXRedirect = "HX-Redirect"

hHXRefresh :: HeaderName
hHXRefresh = "HX-Refresh"

hHXReplaceUrl :: HeaderName
hHXReplaceUrl = "HX-Replace-Url"

hHXRequest :: HeaderName
hHXRequest = "HX-Request"

hHXRequestType :: HeaderName
hHXRequestType = "HX-Request-Type"

hHXReselect :: HeaderName
hHXReselect = "HX-Reselect"

hHXReswap :: HeaderName
hHXReswap = "HX-Reswap"

hHXRetarget :: HeaderName
hHXRetarget = "HX-Retarget"

hHXSource :: HeaderName
hHXSource = "HX-Source"

hHXTarget :: HeaderName
hHXTarget = "HX-Target"

hHXTrigger :: HeaderName
hHXTrigger = "HX-Trigger"

-- * Shared shapes

-- | A CSS selector, e.g. @#results@.
-- <https://four.htmx.org/reference/headers/HX-Retarget>
newtype CssSelector = CssSelector { unCssSelector :: Text }
  deriving (Eq, Show)

-- | Smart constructor: surrounding whitespace is insignificant, an empty
-- selector is not a selector.
mkCssSelector :: Text -> Either Text CssSelector
mkCssSelector raw =
  case T.strip raw of
    ""       -> Left "empty CSS selector"
    selector -> Right (CssSelector selector)

instance FromHttpApiData CssSelector where
  parseUrlPiece = mkCssSelector
  parseHeader = parseHeaderBytes mkCssSelector

instance ToHttpApiData CssSelector where
  toUrlPiece = unCssSelector
  toHeader = encodeUtf8 . unCssSelector

-- | An element reference of the form @tag#id@, e.g. @button#submit@.
-- Shared by @HX-Source@ and @HX-Target@.
-- <https://four.htmx.org/reference/headers/HX-Source>
data ElementRef = ElementRef
  { elementTag :: !Text
  , elementId  :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Smart constructor: the tag is required, the @#id@ part is optional, a
-- dangling @#@ or whitespace is rejected.
parseElementRef :: Text -> Either Text ElementRef
parseElementRef raw =
  case T.breakOn "#" (T.strip raw) of
    ("", _) -> Left ("empty element tag in " <> quote raw)
    (tag, "")
      | T.any isSpace tag -> Left ("whitespace in element tag " <> quote raw)
      | otherwise -> Right (ElementRef tag Nothing)
    (tag, rest)
      | T.any isSpace tag -> Left ("whitespace in element tag " <> quote raw)
      | T.null (T.drop 1 rest) -> Left ("dangling '#' in " <> quote raw)
      | T.any isSpace rest -> Left ("whitespace in element id " <> quote raw)
      | otherwise -> Right (ElementRef tag (Just (T.drop 1 rest)))

instance FromHttpApiData ElementRef where
  parseUrlPiece = parseElementRef
  parseHeader = parseHeaderBytes parseElementRef

instance ToHttpApiData ElementRef where
  toUrlPiece (ElementRef tag Nothing)   = tag
  toUrlPiece (ElementRef tag (Just eid)) = tag <> "#" <> eid
  toHeader = encodeUtf8 . toUrlPiece

-- | @HX-Push-Url@ \/ @HX-Replace-Url@: either a URL for the location bar or
-- @false@, which leaves browser history alone.
-- <https://four.htmx.org/reference/headers/HX-Push-Url>
data HistoryUrl
  = HistoryUrl !Text
  | NoHistoryUpdate
  deriving (Eq, Show)

parseHistoryUrl :: Text -> Either Text HistoryUrl
parseHistoryUrl raw =
  case T.strip raw of
    ""      -> Left "empty history URL"
    "false" -> Right NoHistoryUpdate
    url     -> Right (HistoryUrl url)

instance FromHttpApiData HistoryUrl where
  parseUrlPiece = parseHistoryUrl
  parseHeader = parseHeaderBytes parseHistoryUrl

instance ToHttpApiData HistoryUrl where
  toUrlPiece (HistoryUrl url) = url
  toUrlPiece NoHistoryUpdate  = "false"
  toHeader = encodeUtf8 . toUrlPiece

-- * Request headers

-- | @HX-Request: true@ — the request was made by htmx. A unit type: the only
-- value htmx ever sends is @true@, so anything else is a parse error.
-- <https://four.htmx.org/reference/headers/HX-Request>
data IsHtmxRequest = IsHtmxRequest
  deriving (Eq, Show)

parseIsHtmxRequest :: Text -> Either Text IsHtmxRequest
parseIsHtmxRequest raw =
  case T.strip raw of
    "true" -> Right IsHtmxRequest
    other  -> Left ("expected \"true\" for HX-Request, got " <> quote other)

instance FromHttpApiData IsHtmxRequest where
  parseUrlPiece = parseIsHtmxRequest
  parseHeader = parseHeaderBytes parseIsHtmxRequest

instance ToHttpApiData IsHtmxRequest where
  toUrlPiece _ = "true"
  toHeader _ = "true"

-- | @HX-Request-Type@: whether the request targets one element or the whole
-- page. <https://four.htmx.org/reference/headers/HX-Request-Type>
data RequestType
  = PartialFragment
  | FullPage
  deriving (Eq, Show)

parseRequestType :: Text -> Either Text RequestType
parseRequestType raw =
  case T.strip raw of
    "partial" -> Right PartialFragment
    "full"    -> Right FullPage
    other     -> Left ("expected \"partial\" or \"full\" for HX-Request-Type, got " <> quote other)

instance FromHttpApiData RequestType where
  parseUrlPiece = parseRequestType
  parseHeader = parseHeaderBytes parseRequestType

instance ToHttpApiData RequestType where
  toUrlPiece PartialFragment = "partial"
  toUrlPiece FullPage        = "full"
  toHeader = encodeUtf8 . toUrlPiece

-- | @HX-Boosted: true@ — the request comes from a boosted element.
-- <https://four.htmx.org/reference/headers/HX-Boosted>
data IsBoosted = IsBoosted
  deriving (Eq, Show)

parseIsBoosted :: Text -> Either Text IsBoosted
parseIsBoosted raw =
  case T.strip raw of
    "true" -> Right IsBoosted
    other  -> Left ("expected \"true\" for HX-Boosted, got " <> quote other)

instance FromHttpApiData IsBoosted where
  parseUrlPiece = parseIsBoosted
  parseHeader = parseHeaderBytes parseIsBoosted

instance ToHttpApiData IsBoosted where
  toUrlPiece _ = "true"
  toHeader _ = "true"

-- | @HX-Current-URL@: the browser URL when the request was made.
-- <https://four.htmx.org/reference/headers/HX-Current-URL>
newtype CurrentUrl = CurrentUrl { unCurrentUrl :: Text }
  deriving (Eq, Show)

mkCurrentUrl :: Text -> Either Text CurrentUrl
mkCurrentUrl raw =
  case T.strip raw of
    ""  -> Left "empty HX-Current-URL"
    url -> Right (CurrentUrl url)

instance FromHttpApiData CurrentUrl where
  parseUrlPiece = mkCurrentUrl
  parseHeader = parseHeaderBytes mkCurrentUrl

instance ToHttpApiData CurrentUrl where
  toUrlPiece = unCurrentUrl
  toHeader = encodeUtf8 . unCurrentUrl

-- | @HX-History-Restore-Request: true@ — back\/forward navigation.
-- <https://four.htmx.org/reference/headers/HX-History-Restore-Request>
data IsHistoryRestore = IsHistoryRestore
  deriving (Eq, Show)

parseIsHistoryRestore :: Text -> Either Text IsHistoryRestore
parseIsHistoryRestore raw =
  case T.strip raw of
    "true" -> Right IsHistoryRestore
    other  -> Left ("expected \"true\" for HX-History-Restore-Request, got " <> quote other)

instance FromHttpApiData IsHistoryRestore where
  parseUrlPiece = parseIsHistoryRestore
  parseHeader = parseHeaderBytes parseIsHistoryRestore

instance ToHttpApiData IsHistoryRestore where
  toUrlPiece _ = "true"
  toHeader _ = "true"

-- * Response headers

-- | @HX-Location@: redirect without a full page load. Either a bare path or
-- a swap context serialised as JSON (authoritative) or HCON
-- (<https://four.htmx.org/docs/hcon-guide>).
-- <https://four.htmx.org/reference/headers/HX-Location>
data Location
  = LocationPath !Text
  | LocationSwap !LocationContext
  deriving (Eq, Show)

-- | The structured form: @path@ is required, @target@ and @select@ are CSS
-- selectors. Only these three @htmx.ajax()@ options are modelled; anything
-- else is rejected so callers notice instead of silently dropping it.
data LocationContext = LocationContext
  { locationPath   :: !Text
  , locationTarget :: !(Maybe CssSelector)
  , locationSelect :: !(Maybe CssSelector)
  }
  deriving (Eq, Show)

parseLocation :: Text -> Either Text Location
parseLocation raw =
  case T.strip raw of
    "" -> Left "empty HX-Location"
    stripped
      | "{" `T.isPrefixOf` stripped -> parseLocationJson stripped
      | T.any isSpace stripped || T.elem ',' stripped -> LocationSwap <$> parseLocationHcon stripped
      | otherwise -> Right (LocationPath stripped)

parseLocationJson :: Text -> Either Text Location
parseLocationJson raw =
  case Aeson.eitherDecodeStrict (encodeUtf8 raw) of
    Left err -> Left ("invalid HX-Location JSON: " <> T.pack err)
    Right (Object obj) -> do
      path <- case KeyMap.lookup "path" obj of
        Just (String p) | not (T.null (T.strip p)) -> Right (T.strip p)
        _ -> Left "HX-Location JSON object requires a non-empty \"path\" string"
      target <- parseOptionalSelector "target" obj
      select <- parseOptionalSelector "select" obj
      Right (LocationSwap (LocationContext path target select))
    Right _ -> Left "HX-Location JSON must be an object"

parseOptionalSelector :: Key.Key -> KeyMap.KeyMap Value -> Either Text (Maybe CssSelector)
parseOptionalSelector key obj =
  case KeyMap.lookup key obj of
    Nothing      -> Right Nothing
    Just Null    -> Right Nothing
    Just (String s) -> Just <$> mkCssSelector s
    Just _       -> Left ("HX-Location JSON field " <> quote (Key.toText key) <> " must be a string")

-- | Flat HCON subset for the documented keys, e.g.
-- @path:/search target:#results select:#matches@. A single bare token is the
-- path; every @key:value@ pair must use a known key.
parseLocationHcon :: Text -> Either Text LocationContext
parseLocationHcon raw = do
  let tokens = T.words (T.map (\c -> if c == ',' then ' ' else c) raw)
  (path, target, select) <- foldM step (Nothing, Nothing, Nothing) tokens
  case path of
    Nothing -> Left ("HX-Location HCON requires a path: " <> quote raw)
    Just p  -> Right (LocationContext p target select)
  where
    step (path, target, select) token =
      case T.breakOn ":" token of
        (_, "") -> case path of
          Just _  -> Left ("multiple bare paths in HX-Location HCON: " <> quote raw)
          Nothing -> Right (Just (T.strip token), target, select)
        (key, rest) -> do
          value <- unquote (T.drop 1 rest)
          case T.strip key of
            "path"   -> Right (Just value, target, select)
            "target" -> (\t -> (path, Just t, select)) <$> mkCssSelector value
            "select" -> (\s -> (path, target, Just s)) <$> mkCssSelector value
            unknown  -> Left ("unknown HX-Location HCON key " <> quote unknown)

unquote :: Text -> Either Text Text
unquote value =
  case T.uncons value of
    Just ('"', rest) -> quoted '"' rest
    Just ('\'', rest) -> quoted '\'' rest
    _ -> Right value
  where
    quoted q rest =
      case T.unsnoc rest of
        Just (inner, c) | c == q -> Right inner
        _ -> Left ("unterminated quote in " <> quote value)

instance FromHttpApiData Location where
  parseUrlPiece = parseLocation
  parseHeader = parseHeaderBytes parseLocation

instance ToHttpApiData Location where
  toUrlPiece (LocationPath path) = path
  toUrlPiece (LocationSwap ctx)  = toUrlPiece ctx
  toHeader = encodeUtf8 . toUrlPiece

instance ToHttpApiData LocationContext where
  toUrlPiece (LocationContext path Nothing Nothing) = path
  toUrlPiece (LocationContext path target select) =
    decodeUtf8 (LBS.toStrict (Aeson.encode (Aeson.object fields)))
    where
      fields =
        ["path" Aeson..= path]
          <> ["target" Aeson..= unCssSelector t | Just t <- [target]]
          <> ["select" Aeson..= unCssSelector s | Just s <- [select]]
  toHeader = encodeUtf8 . toUrlPiece

-- | @HX-Redirect@: full-page redirect to a URL.
-- <https://four.htmx.org/reference/headers/HX-Redirect>
newtype RedirectUrl = RedirectUrl { unRedirectUrl :: Text }
  deriving (Eq, Show)

mkRedirectUrl :: Text -> Either Text RedirectUrl
mkRedirectUrl raw =
  case T.strip raw of
    ""  -> Left "empty HX-Redirect"
    url -> Right (RedirectUrl url)

instance FromHttpApiData RedirectUrl where
  parseUrlPiece = mkRedirectUrl
  parseHeader = parseHeaderBytes mkRedirectUrl

instance ToHttpApiData RedirectUrl where
  toUrlPiece = unRedirectUrl
  toHeader = encodeUtf8 . unRedirectUrl

-- | @HX-Refresh: true@ — reload the page via @location.reload()@.
-- <https://four.htmx.org/reference/headers/HX-Refresh>
data RefreshPage = RefreshPage
  deriving (Eq, Show)

parseRefreshPage :: Text -> Either Text RefreshPage
parseRefreshPage raw =
  case T.strip raw of
    "true" -> Right RefreshPage
    other  -> Left ("expected \"true\" for HX-Refresh, got " <> quote other)

instance FromHttpApiData RefreshPage where
  parseUrlPiece = parseRefreshPage
  parseHeader = parseHeaderBytes parseRefreshPage

instance ToHttpApiData RefreshPage where
  toUrlPiece _ = "true"
  toHeader _ = "true"

-- | @HX-Reswap@: swap spec overriding the triggering element's @hx-swap@,
-- e.g. @outerHTML@ or @innerHTML transition:true@. Kept opaque: the swap
-- grammar (strategies plus modifiers) is its own language; a total parser
-- for it is out of scope, so the boundary only rejects empties.
-- <https://four.htmx.org/reference/headers/HX-Reswap>
newtype SwapSpec = SwapSpec { unSwapSpec :: Text }
  deriving (Eq, Show)

mkSwapSpec :: Text -> Either Text SwapSpec
mkSwapSpec raw =
  case T.strip raw of
    ""   -> Left "empty HX-Reswap"
    spec -> Right (SwapSpec spec)

instance FromHttpApiData SwapSpec where
  parseUrlPiece = mkSwapSpec
  parseHeader = parseHeaderBytes mkSwapSpec

instance ToHttpApiData SwapSpec where
  toUrlPiece = unSwapSpec
  toHeader = encodeUtf8 . unSwapSpec

-- | A client-side event name, e.g. @cartUpdated@.
newtype EventName = EventName { unEventName :: Text }
  deriving (Eq, Show)

mkEventName :: Text -> Either Text EventName
mkEventName raw =
  case T.strip raw of
    ""   -> Left "empty event name"
    name -> Right (EventName name)

instance FromHttpApiData EventName where
  parseUrlPiece = mkEventName
  parseHeader = parseHeaderBytes mkEventName

instance ToHttpApiData EventName where
  toUrlPiece = unEventName
  toHeader = encodeUtf8 . unEventName

-- | One @HX-Trigger@ event: a name with optional detail payload and optional
-- targeted element. A scalar JSON detail is normalised exactly the way htmx
-- normalises it on receipt — available on the client as @detail.value@ —
-- while a @target@ key is split out into 'triggerTarget'.
-- <https://four.htmx.org/reference/headers/HX-Trigger>
data TriggerEvent = TriggerEvent
  { triggerName   :: !EventName
  , triggerDetail :: !(Maybe Value)
  , triggerTarget :: !(Maybe CssSelector)
  }
  deriving (Eq, Show)

-- | The @HX-Trigger@ response header: one or more events. A single bare
-- event renders as its name (@myEvent@); anything with detail or targets
-- renders as a JSON object, mirroring the documented wire shapes
-- (@event1, event2@ and @{"notification":"Saved"}@).
-- <https://four.htmx.org/reference/headers/HX-Trigger>
newtype TriggerEvents = TriggerEvents { unTriggerEvents :: NonEmpty TriggerEvent }
  deriving (Eq, Show)

parseTriggerEvents :: Text -> Either Text TriggerEvents
parseTriggerEvents raw =
  case T.strip raw of
    "" -> Left "empty HX-Trigger"
    stripped
      | "{" `T.isPrefixOf` stripped -> parseTriggerJson stripped
      | otherwise -> do
          events <- traverse (parseBareEvent . T.strip) (T.splitOn "," stripped)
          case nonEmpty events of
            Nothing -> Left "empty HX-Trigger"
            Just ne -> Right (TriggerEvents ne)
  where
    parseBareEvent name = do
      eventName <- mkEventName name
      Right (TriggerEvent eventName Nothing Nothing)

parseTriggerJson :: Text -> Either Text TriggerEvents
parseTriggerJson raw =
  case Aeson.eitherDecodeStrict (encodeUtf8 raw) of
    Left err -> Left ("invalid HX-Trigger JSON: " <> T.pack err)
    Right (Object obj)
      | KeyMap.null obj -> Left "empty HX-Trigger JSON object"
      | otherwise -> case nonEmpty (KeyMap.toList obj) of
          Nothing -> Left "empty HX-Trigger JSON object"
          Just pairs -> TriggerEvents <$> traverse parseMember pairs
    Right _ -> Left "HX-Trigger JSON must be an object"
  where
    parseMember (key, value) = do
      eventName <- mkEventName (Key.toText key)
      (detail, target) <- case value of
        Object fields -> case KeyMap.lookup "target" fields of
          Just (String selector) -> do
            css <- mkCssSelector selector
            let rest = KeyMap.delete "target" fields
            Right (if KeyMap.null rest then Nothing else Just (Object rest), Just css)
          Just _ -> Left ("HX-Trigger event " <> quote (Key.toText key) <> " has a non-string \"target\"")
          Nothing -> Right (Just (Object fields), Nothing)
        _ -> Right (Just value, Nothing)
      Right (TriggerEvent eventName detail target)

instance FromHttpApiData TriggerEvents where
  parseUrlPiece = parseTriggerEvents
  parseHeader = parseHeaderBytes parseTriggerEvents

instance ToHttpApiData TriggerEvents where
  toUrlPiece (TriggerEvents (event :| []))
    | Nothing <- triggerDetail event
    , Nothing <- triggerTarget event =
        unEventName (triggerName event)
  toUrlPiece (TriggerEvents events) =
    decodeUtf8 (LBS.toStrict (Aeson.encode (Aeson.object (toList (renderEvent <$> events)))))
    where
      renderEvent (TriggerEvent name detail target) =
        Key.fromText (unEventName name) Aeson..= renderDetail detail target
      renderDetail Nothing Nothing         = Null
      renderDetail Nothing (Just t)        = Object (KeyMap.singleton "target" (String (unCssSelector t)))
      renderDetail (Just d) Nothing        = d
      -- htmx exposes scalar detail as detail.value, so a targeted scalar is
      -- emitted wrapped: {"value": detail, "target": selector}.
      renderDetail (Just d@(Object _)) (Just t) =
        Object (KeyMap.insert "target" (String (unCssSelector t)) fields)
        where Object fields = d
      renderDetail (Just d) (Just t) =
        Aeson.object ["value" Aeson..= d, "target" Aeson..= unCssSelector t]
  toHeader = encodeUtf8 . toUrlPiece

-- * WAI boundary helpers

-- | Look up a request header and parse it. 'Nothing' (right) means absent;
-- 'Left' means present but unparsable — the WAI analogue of servant turning
-- a failed 'parseHeader' into a 400.
lookupParsedHeader :: FromHttpApiData a => HeaderName -> Request -> Either Text (Maybe a)
lookupParsedHeader name req =
  case lookup name (requestHeaders req) of
    Nothing  -> Right Nothing
    Just raw -> Just <$> parseHeader raw

-- | Set a response header, serialising with 'toHeader'.
withResponseHeader :: ToHttpApiData a => HeaderName -> a -> Response -> Response
withResponseHeader name value = mapResponseHeaders ((name, toHeader value) :)

-- * Internals

-- | Decode raw header bytes as UTF-8 (strict: invalid bytes are an error,
-- not replacement characters) and run a 'Text' parser.
parseHeaderBytes :: (Text -> Either Text a) -> ByteString -> Either Text a
parseHeaderBytes parse raw =
  case decodeUtf8' raw of
    Left err -> Left ("invalid UTF-8 in header value: " <> show err)
    Right text -> parse text

quote :: Text -> Text
quote text = "\"" <> text <> "\""
