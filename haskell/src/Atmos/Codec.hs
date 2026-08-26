-- | Line-oriented encoding for the home-grown stores.
--
-- Paths may contain anything except NUL and @\/@, so a record separated by
-- literal tabs and newlines is not safe on its own.  We escape the three
-- characters that would break framing and leave everything else alone, which
-- keeps the files greppable and diffable — the main reason to prefer plain
-- text over a database here.
module Atmos.Codec
  ( encodeField
  , decodeField
  , encodeRecord
  , decodeRecord
  , percentEncode
  , percentDecode
  ) where

import Data.Char (chr, isDigit, isHexDigit, ord, toUpper)
import Data.List (intercalate)
import Numeric (readHex, showHex)

-- | Escape the framing characters: backslash, tab, newline, carriage return.
encodeField :: String -> String
encodeField = concatMap esc
  where
    esc '\\' = "\\\\"
    esc '\t' = "\\t"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc c = [c]

decodeField :: String -> String
decodeField [] = []
decodeField ('\\' : c : rest) = unesc c ++ decodeField rest
  where
    unesc '\\' = "\\"
    unesc 't' = "\t"
    unesc 'n' = "\n"
    unesc 'r' = "\r"
    unesc x = ['\\', x] -- unknown escape: keep it verbatim rather than lose data
decodeField (c : rest) = c : decodeField rest

encodeRecord :: [String] -> String
encodeRecord = intercalate "\t" . map encodeField

decodeRecord :: String -> [String]
decodeRecord = map decodeField . splitOn '\t'

splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
  (a, []) -> [a]
  (a, _ : b) -> a : splitOn sep b

-- | Library and namespace names become filenames in the file-per-library
-- store, so anything that is not obviously safe is percent-encoded.  Names
-- that are already plain (the overwhelmingly common case) pass through
-- untouched, so the directory stays readable.
percentEncode :: String -> String
percentEncode = concatMap enc
  where
    enc c
      | c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || isDigit c = [c]
      | c `elem` ("-._" :: String) = [c]
      | otherwise = '%' : pad (map toUpper (showHex (ord c) ""))
    pad [d] = ['0', d]
    pad ds = ds

percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : a : b : rest)
  | isHexDigit a && isHexDigit b
  , [(n, "")] <- readHex [a, b] =
      chr n : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest
