{-# LANGUAGE TemplateHaskell, OverloadedStrings #-}

module HsDev.Tools.Types (
	Severity(..),
	Note(..), noteSource, noteRegion, noteLevel, note,
	OutputMessage(..), message, messageSuggestion, outputMessage
	) where

import Control.DeepSeq (NFData(..))
import Control.Lens (makeLenses)
import Control.Monad
import Data.Aeson hiding (Error)

import HsDev.Symbols (Canonicalize(..))
import HsDev.Symbols.Location
import HsDev.Util ((.::))

-- | Note severity
data Severity = Error | Warning | Hint deriving (Enum, Bounded, Eq, Ord, Read, Show)

instance NFData Severity where
	rnf Error = ()
	rnf Warning = ()
	rnf Hint = ()

instance ToJSON Severity where
	toJSON Error = toJSON ("error" :: String)
	toJSON Warning = toJSON ("warning" :: String)
	toJSON Hint = toJSON ("hint" :: String)

instance FromJSON Severity where
	parseJSON v = do
		s <- parseJSON v
		msum [
			guard (s == ("error" :: String)) >> return Error,
			guard (s == ("warning" :: String)) >> return Warning,
			guard (s == ("hint" :: String)) >> return Hint,
			fail $ "Unknown severity: " ++ s]

-- | Note over some region
data Note a = Note {
	_noteSource :: ModuleLocation,
	_noteRegion :: Region,
	_noteLevel :: Severity,
	_note :: a }

makeLenses ''Note

instance Functor Note where
	fmap f (Note s r l n) = Note s r l (f n)

instance NFData a => NFData (Note a) where
	rnf (Note s r l n) = rnf s `seq` rnf r `seq` rnf l `seq` rnf n

instance ToJSON a => ToJSON (Note a) where
	toJSON (Note s r l n) = object [
		"source" .= s,
		"region" .= r,
		"level" .= l,
		"note" .= n]

instance FromJSON a => FromJSON (Note a) where
	parseJSON = withObject "note" $ \v -> Note <$>
		v .:: "source" <*>
		v .:: "region" <*>
		v .:: "level" <*>
		v .:: "note"

instance RecalcTabs (Note a) where
	recalcTabs cts (Note s r l n) = Note s (recalcTabs cts r) l n

instance Canonicalize (Note a) where
	canonicalize (Note s r l n) = Note <$> canonicalize s <*> pure r <*> pure l <*> pure n

-- | Output message from some tool (ghc, ghc-mod, hlint) with optional suggestion
data OutputMessage = OutputMessage {
	_message :: String,
	_messageSuggestion :: Maybe String }

instance NFData OutputMessage where
	rnf (OutputMessage m s) = rnf m `seq` rnf s

instance ToJSON OutputMessage where
	toJSON (OutputMessage m s) = object [
		"message" .= m,
		"suggestion" .= s]

instance FromJSON OutputMessage where
	parseJSON = withObject "output-message" $ \v -> OutputMessage <$>
		v .:: "message" <*>
		v .:: "suggestion"

outputMessage :: String -> OutputMessage
outputMessage msg = OutputMessage msg Nothing

makeLenses ''OutputMessage