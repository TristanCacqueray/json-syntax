{-# language BangPatterns #-}
{-# language BinaryLiterals #-}
{-# language BlockArguments #-}
{-# language DerivingStrategies #-}
{-# language DeriveAnyClass #-}
{-# language LambdaCase #-}
{-# language MagicHash #-}
{-# language NamedFieldPuns #-}
{-# language PatternSynonyms #-}
{-# language TypeApplications #-}
{-# language UnboxedTuples #-}

module Json
  ( -- * Types
    Value(..)
  , Member(..)
  , SyntaxException(..)
    -- * Functions
  , decode
  , encode
    -- * Infix Synonyms 
  , pattern (:->)
  ) where

import Prelude hiding (Bool(True,False))

import Control.Exception (Exception)
import Control.Monad.ST (ST)
import Data.Bits ((.&.),(.|.),unsafeShiftR)
import Data.Builder.ST (Builder)
import Data.Bytes.Parser (Parser)
import Data.Bytes.Types (Bytes(..))
import Data.Char (ord)
import Data.Chunks (Chunks(ChunksNil,ChunksCons))
import Data.Number.Scientific (Scientific)
import Data.Primitive (ByteArray,MutableByteArray)
import Data.Text.Short (ShortText)
import GHC.Exts (Char(C#),Int(I#),gtWord#,ltWord#,word2Int#,chr#)
import GHC.Word (Word8(W8#),Word16(W16#))

import qualified Prelude
import qualified Data.Builder.ST as B
import qualified Data.Bytes.Builder as BLDR
import qualified Data.Bytes.Parser as P
import qualified Data.Text.Short.Unsafe as TS
import qualified Data.Number.Scientific as SCI
import qualified Data.Primitive as PM
import qualified Data.Bytes.Parser.Utf8 as Utf8
import qualified Data.Bytes.Parser.Latin as Latin
import qualified Data.ByteString.Short.Internal as BSS
import qualified Data.Bytes.Parser.Unsafe as Unsafe

-- | The JSON syntax tree described by the ABNF in RFC 7159. Notable
-- design decisions include:
--
-- * @True@ and @False@ are their own data constructors rather than
--   being lumped together under a data constructor for boolean values.
--   This improves performance when decoding the syntax tree to a @Bool@.
-- * @Object@ uses an association list rather than a hash map. This is
--   the data type that key-value pairs can be parsed into most cheaply.
-- * @Object@ and @Array@ both use 'Chunks' rather than using @SmallArray@
--   or cons-list directly. This a middle ground between those two types. We
--   get the efficent use of cache lines that @SmallArray@ offers, and we get
--   the worst-case @O(1)@ appends that cons-list offers. Users will typically
--   fold over the elements with the @Foldable@ instance of 'Chunks', although
--   there are functions in @Data.Chunks@ that efficently perform other
--   operations.
data Value
  = Object !(Chunks Member)
  | Array !(Chunks Value)
  | String {-# UNPACK #-} !ShortText
  | Number {-# UNPACK #-} !Scientific
  | Null
  | True
  | False
  deriving stock (Eq,Show)

-- | Exceptions that can happen while parsing JSON. Do not pattern
-- match on values of this type. New data constructors may be added
-- at any time without a major version bump.
data SyntaxException
  = EmptyInput
  | ExpectedColon
  | ExpectedCommaOrRightBracket
  | ExpectedFalse
  | ExpectedNull
  | ExpectedQuote
  | ExpectedQuoteOrRightBrace
  | ExpectedTrue
  | IncompleteArray
  | IncompleteEscapeSequence
  | IncompleteObject
  | IncompleteString
  | InvalidEscapeSequence
  | InvalidLeader
  | InvalidNumber
  | LeadingZero
  | UnexpectedLeftovers
  deriving stock (Eq,Show)
  deriving anyclass (Exception)

-- | A key-value pair in a JSON object. The name of this type is
-- taken from section 4 of RFC 7159.
data Member = Member
  { key :: {-# UNPACK #-} !ShortText
  , value :: !Value
  } deriving stock (Eq,Show)

emptyArrayValue :: Value
{-# noinline emptyArrayValue #-}
emptyArrayValue = Array ChunksNil

emptyObjectValue :: Value
{-# noinline emptyObjectValue #-}
emptyObjectValue = Object ChunksNil

isSpace :: Word8 -> Prelude.Bool
isSpace w =
     w == c2w ' '
  || w == c2w '\t'
  || w == c2w '\r'
  || w == c2w '\n'

-- | Decode a JSON syntax tree from a byte sequence.
decode :: Bytes -> Either SyntaxException Value
decode = P.parseBytesEither do
  P.skipWhile isSpace
  result <- Latin.any EmptyInput >>= parser
  P.skipWhile isSpace
  P.endOfInput UnexpectedLeftovers
  pure result

-- | Encode a JSON syntax tree.
encode :: Value -> BLDR.Builder
encode = \case
  True -> BLDR.ascii4 't' 'r' 'u' 'e'
  False -> BLDR.ascii5 'f' 'a' 'l' 's' 'e'
  Null -> BLDR.ascii4 'n' 'u' 'l' 'l'
  String s -> BLDR.shortTextJsonString s
  Number n -> SCI.builderUtf8 n
  Array ys -> case unconsNonempty ys of
    Nothing -> BLDR.ascii2 '[' ']'
    Just (x,xs) ->
      BLDR.ascii '['
      <>
      encode (PM.indexSmallArray x 0)
      <>
      foldrTail
        ( \v b -> BLDR.ascii ',' <> encode v <> b
        )
        ( foldr
          ( \v b -> BLDR.ascii ',' <> encode v <> b
          ) (BLDR.ascii ']') xs
        )
        x
  Object ys -> case unconsNonempty ys of
    Nothing -> BLDR.ascii2 '{' '}'
    Just (x,xs) ->
      BLDR.ascii '{'
      <>
      encodeMember (PM.indexSmallArray x 0)
      <>
      foldrTail
        ( \mbr b -> BLDR.ascii ',' <> encodeMember mbr <> b
        )
        ( foldr
          ( \mbr b -> BLDR.ascii ',' <> encodeMember mbr <> b
          ) (BLDR.ascii '}') xs
        )
        x

encodeMember :: Member -> BLDR.Builder
encodeMember Member{key,value} =
  BLDR.shortTextJsonString key
  <>
  BLDR.ascii ':'
  <>
  encode value

foldrTail :: (a -> b -> b) -> b -> PM.SmallArray a -> b
{-# inline foldrTail #-}
foldrTail f z !ary = go 1 where
  !sz = PM.sizeofSmallArray ary
  go i
    | i == sz = z
    | (# x #) <- PM.indexSmallArray## ary i
    = f x (go (i+1))

-- Get the first non-empty SmallArray from the Chunks.
unconsNonempty :: Chunks a -> Maybe (PM.SmallArray a, Chunks a)
{-# inline unconsNonempty #-}
unconsNonempty = go where
  go ChunksNil = Nothing
  go (ChunksCons x xs) = case PM.sizeofSmallArray x of
    0 -> go xs
    _ -> Just (x,xs)

-- Precondition: skip over all space before calling this.
-- It will not skip leading space for you. It does
parser :: Char -> Parser SyntaxException s Value
parser = \case
  '{' -> objectTrailedByBrace
  '[' -> arrayTrailedByBracket
  't' -> do
    Latin.char3 ExpectedTrue 'r' 'u' 'e'
    pure True
  'f' -> do
    Latin.char4 ExpectedFalse 'a' 'l' 's' 'e'
    pure False
  'n' -> do
    Latin.char3 ExpectedNull 'u' 'l' 'l'
    pure Null
  '"' -> do
    start <- Unsafe.cursor
    string String start
  '-' -> fmap Number (SCI.parserNegatedUtf8Bytes InvalidNumber)
  '0' -> Latin.trySatisfy (\c -> c >= '0' && c <= '9') >>= \case
    Prelude.True -> P.fail LeadingZero
    Prelude.False -> fmap Number (SCI.parserTrailingUtf8Bytes InvalidNumber 0)
  c | c >= '1' && c <= '9' ->
        fmap Number (SCI.parserTrailingUtf8Bytes InvalidNumber (ord c - 48))
  _ -> P.fail InvalidLeader

objectTrailedByBrace :: Parser SyntaxException s Value
objectTrailedByBrace = do
  P.skipWhile isSpace
  Latin.any IncompleteObject >>= \case
    '}' -> pure emptyObjectValue
    '"' -> do
      start <- Unsafe.cursor
      !theKey <- string id start
      P.skipWhile isSpace
      Latin.char ExpectedColon ':'
      P.skipWhile isSpace
      val <- Latin.any IncompleteObject >>= parser
      let !mbr = Member theKey val
      !b0 <- P.effect B.new
      b1 <- P.effect (B.push mbr b0)
      objectStep b1
    _ -> P.fail ExpectedQuoteOrRightBrace

objectStep :: Builder s Member -> Parser SyntaxException s Value
objectStep !b = do
  P.skipWhile isSpace
  Latin.any IncompleteObject >>= \case
    ',' -> do
      P.skipWhile isSpace
      Latin.char ExpectedQuote '"'
      start <- Unsafe.cursor
      !theKey <- string id start
      P.skipWhile isSpace
      Latin.char ExpectedColon ':'
      P.skipWhile isSpace
      val <- Latin.any IncompleteObject >>= parser
      let !mbr = Member theKey val
      P.effect (B.push mbr b) >>= objectStep
    '}' -> do
      !r <- P.effect (B.freeze b)
      pure (Object r)
    _ -> P.fail ExpectedCommaOrRightBracket

-- This eats all the space at the front of the input. There
-- is no need to skip over it before calling this function.
-- RFC 7159 defines array as:
--
-- > begin-array = ws LBRACKET ws
-- > array = begin-array [ value *( value-separator value ) ] end-array
--
-- This parser handles everything after the LBRACKET character.
arrayTrailedByBracket :: Parser SyntaxException s Value
arrayTrailedByBracket = do
  P.skipWhile isSpace
  Latin.any IncompleteArray >>= \case
    ']' -> pure emptyArrayValue
    c -> do
      !b0 <- P.effect B.new
      val <- parser c
      b1 <- P.effect (B.push val b0)
      arrayStep b1

-- From RFC 7159:
--
-- > value-separator = ws COMMA ws 
-- > array = begin-array [ value *( value-separator value ) ] end-array
--
-- This handles the all values after the first one. That is:
--
-- > *( value-separator value )
arrayStep :: Builder s Value -> Parser SyntaxException s Value
arrayStep !b = do
  P.skipWhile isSpace
  Latin.any IncompleteArray >>= \case
    ',' -> do
      P.skipWhile isSpace
      val <- Latin.any IncompleteArray >>= parser
      P.effect (B.push val b) >>= arrayStep
    ']' -> do
      !r <- P.effect (B.freeze b)
      pure (Array r)
    _ -> P.fail ExpectedCommaOrRightBracket

c2w :: Char -> Word8
c2w = fromIntegral . ord

-- This is adapted from the function bearing the same name
-- in json-tokens. If you find a problem with it, then
-- something if wrong in json-tokens as well.
--
-- TODO: Quit doing this CPS and inline nonsense. We should
-- be able to unbox the resulting ShortText as ByteArray# and
-- mark the function as NOINLINE. This would prevent the generated
-- code from being needlessly duplicated in three different places.
string :: (ShortText -> a) -> Int -> Parser SyntaxException s a
{-# inline string #-}
string wrap !start = go 1 where
  go !canMemcpy = do
    P.any IncompleteString >>= \case
      92 -> P.any InvalidEscapeSequence *> go 0 -- backslash
      34 -> do -- double quote
        !pos <- Unsafe.cursor
        case canMemcpy of
          1 -> do
            src <- Unsafe.expose
            str <- P.effect $ do
              let end = pos - 1
              let len = end - start
              dst <- PM.newByteArray len
              PM.copyByteArray dst 0 src start len
              PM.unsafeFreezeByteArray dst
            pure (wrap (TS.fromShortByteStringUnsafe (byteArrayToShortByteString str)))
          _ -> do
            Unsafe.unconsume (pos - start)
            let end = pos - 1
            let maxLen = end - start
            copyAndEscape wrap maxLen
      W8# w -> go (canMemcpy .&. I# (ltWord# w 128##) .&. I# (gtWord# w 31##))

copyAndEscape :: (ShortText -> a) -> Int -> Parser SyntaxException s a
{-# inline copyAndEscape #-}
copyAndEscape wrap !maxLen = do
  !dst <- P.effect (PM.newByteArray maxLen)
  let go !ix = Utf8.any# IncompleteString `P.bindFromCharToLifted` \c -> case c of
        '\\'# -> Latin.any IncompleteEscapeSequence >>= \case
          '"' -> do
            P.effect (PM.writeByteArray dst ix (c2w '"'))
            go (ix + 1)
          '\\' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\\'))
            go (ix + 1)
          't' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\t'))
            go (ix + 1)
          'n' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\n'))
            go (ix + 1)
          'r' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\r'))
            go (ix + 1)
          '/' -> do
            P.effect (PM.writeByteArray dst ix (c2w '/'))
            go (ix + 1)
          'b' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\b'))
            go (ix + 1)
          'f' -> do
            P.effect (PM.writeByteArray dst ix (c2w '\f'))
            go (ix + 1)
          'u' -> do
            w <- Latin.hexFixedWord16 InvalidEscapeSequence
            if w >= 0xD800 && w < 0xDFFF
              then go =<< P.effect (encodeUtf8Char dst ix '\xFFFD')
              else go =<< P.effect (encodeUtf8Char dst ix (w16ToChar w))
          _ -> P.fail InvalidEscapeSequence
        '"'# -> do
          str <- P.effect
            (PM.unsafeFreezeByteArray =<< PM.resizeMutableByteArray dst ix)
          pure (wrap (TS.fromShortByteStringUnsafe (byteArrayToShortByteString str)))
        _ -> go =<< P.effect (encodeUtf8Char dst ix (C# c))
  go 0

encodeUtf8Char :: MutableByteArray s -> Int -> Char -> ST s Int
encodeUtf8Char !marr !ix !c
  | c < '\128' = do
      PM.writeByteArray marr ix (c2w c)
      pure (ix + 1)
  | c < '\x0800' = do
      PM.writeByteArray marr ix
        (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 6 .|. 0b11000000))
      PM.writeByteArray marr (ix + 1)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (ord c))))
      pure (ix + 2)
  | c <= '\xffff' = do
      PM.writeByteArray marr ix
        (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 12 .|. 0b11100000))
      PM.writeByteArray marr (ix + 1)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 6))))
      PM.writeByteArray marr (ix + 2)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (ord c))))
      pure (ix + 3)
  | otherwise = do
      PM.writeByteArray marr ix
        (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 18 .|. 0b11110000))
      PM.writeByteArray marr (ix + 1)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 12))))
      PM.writeByteArray marr (ix + 2)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (unsafeShiftR (ord c) 6))))
      PM.writeByteArray marr (ix + 3)
        (0b10000000 .|. (0b00111111 .&. (fromIntegral @Int @Word8 (ord c))))
      pure (ix + 4)

byteArrayToShortByteString :: ByteArray -> BSS.ShortByteString
byteArrayToShortByteString (PM.ByteArray x) = BSS.SBS x

-- Precondition: Not in the range [U+D800 .. U+DFFF]
w16ToChar :: Word16 -> Char
w16ToChar (W16# w) = C# (chr# (word2Int# w))

-- | Infix pattern synonym for 'Member'.
pattern (:->) :: ShortText -> Value -> Member
pattern key :-> value = Member{key,value}
