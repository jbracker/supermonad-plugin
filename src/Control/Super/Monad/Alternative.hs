
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ConstraintKinds #-}

{-# LANGUAGE TypeOperators #-}

module Control.Super.Monad.Alternative
  ( AlternativeEmpty(..)
  , AlternativeAlt(..)
  ) where

import qualified Prelude as P
import qualified Control.Applicative as A

import GHC.Exts ( Constraint )

import qualified GHC.Generics as Generics
import qualified GHC.Conc as STM
import qualified Control.Arrow as Arrow
import qualified Control.Applicative as Applic
import qualified Data.Semigroup as Semigroup
import qualified Data.Proxy as Proxy
import qualified Data.Monoid as Mon
import qualified Text.ParserCombinators.ReadP as ReadP
import qualified Text.ParserCombinators.ReadPrec as ReadPrec

import Control.Super.Monad.Prelude 
  ( ($), (.)
  , Return(..), Applicative(..), Functor(..) )


class Return f => AlternativeEmpty f where
  type AlternativeEmptyCts f :: Constraint
  type AlternativeEmptyCts f = ()
  empty :: AlternativeEmptyCts f => f a

instance AlternativeEmpty [] where
  empty = A.empty
instance AlternativeEmpty P.Maybe where
  empty = A.empty
instance AlternativeEmpty P.IO where
  empty = A.empty
instance AlternativeEmpty ReadP.ReadP where
  empty = A.empty
instance AlternativeEmpty ReadPrec.ReadPrec where
  empty = A.empty
instance AlternativeEmpty STM.STM where
  empty = A.empty
instance AlternativeEmpty Semigroup.Option where
  empty = A.empty
instance AlternativeEmpty Proxy.Proxy where
  empty = A.empty
instance (AlternativeEmpty f) => AlternativeEmpty (Mon.Alt f) where
  type AlternativeEmptyCts (Mon.Alt f) = AlternativeEmptyCts f
  empty = Mon.Alt $ empty

-- TODO: ArrowMonad and WrappedMonad instances. These lead to cyclic dependencies.

instance AlternativeEmpty Generics.U1 where
  empty = A.empty
instance AlternativeEmpty f => AlternativeEmpty (Generics.Rec1 f) where
  type AlternativeEmptyCts (Generics.Rec1 f) = AlternativeEmptyCts f
  empty = Generics.Rec1 empty
instance (AlternativeEmpty f, AlternativeEmpty g) => AlternativeEmpty (f Generics.:*: g) where
  type AlternativeEmptyCts (f Generics.:*: g) = (AlternativeEmptyCts f, AlternativeEmptyCts g)
  empty = empty Generics.:*: empty
instance (AlternativeEmpty f, AlternativeEmpty g) => AlternativeEmpty (f Generics.:.: g) where
  type AlternativeEmptyCts (f Generics.:.: g) = (AlternativeEmptyCts f, AlternativeEmptyCts g)
  empty = Generics.Comp1 $ empty
instance AlternativeEmpty f => AlternativeEmpty (Generics.M1 i c f) where
  type AlternativeEmptyCts (Generics.M1 i c f) = AlternativeEmptyCts f
  empty = Generics.M1 $ empty


class Applicative f g h => AlternativeAlt f g h where
  type AlternativeAltCts f g h :: Constraint
  type AlternativeAltCts f g h = ()
  (<|>) :: AlternativeAltCts f g h => f a -> g a -> h a

instance AlternativeAlt [] [] [] where
  (<|>) = (A.<|>)
instance AlternativeAlt P.Maybe P.Maybe P.Maybe where
  (<|>) = (A.<|>)
instance AlternativeAlt P.IO P.IO P.IO where
  (<|>) = (A.<|>)
instance AlternativeAlt ReadP.ReadP ReadP.ReadP ReadP.ReadP where
  (<|>) = (A.<|>)
instance AlternativeAlt ReadPrec.ReadPrec ReadPrec.ReadPrec ReadPrec.ReadPrec where
  (<|>) = (A.<|>)
instance AlternativeAlt STM.STM STM.STM STM.STM where
  (<|>) = (A.<|>)
instance AlternativeAlt Semigroup.Option Semigroup.Option Semigroup.Option where
  (<|>) = (A.<|>)
instance AlternativeAlt Proxy.Proxy Proxy.Proxy Proxy.Proxy where
  (<|>) = (A.<|>)
instance (AlternativeAlt f g h) => AlternativeAlt (Mon.Alt f) (Mon.Alt g) (Mon.Alt h) where
  type AlternativeAltCts (Mon.Alt f) (Mon.Alt g) (Mon.Alt h) = AlternativeAltCts f g h
  (Mon.Alt ma) <|> (Mon.Alt na) = Mon.Alt $ ma <|> na

-- TODO: ArrowMonad and WrappedMonad instances. These lead to cyclic dependencies.

instance AlternativeAlt Generics.U1 Generics.U1 Generics.U1 where
  (<|>) = (A.<|>)
instance AlternativeAlt f g h => AlternativeAlt (Generics.Rec1 f) (Generics.Rec1 g) (Generics.Rec1 h) where
  type AlternativeAltCts (Generics.Rec1 f) (Generics.Rec1 g) (Generics.Rec1 h) = AlternativeAltCts f g h
  (Generics.Rec1 f) <|> (Generics.Rec1 g) = Generics.Rec1 $ f <|> g
instance (AlternativeAlt f g h, AlternativeAlt f' g' h') => AlternativeAlt (f Generics.:*: f') (g Generics.:*: g') (h Generics.:*: h') where
  type AlternativeAltCts (f Generics.:*: f') (g Generics.:*: g') (h Generics.:*: h') = (AlternativeAltCts f g h, AlternativeAltCts f' g' h')
  (f Generics.:*: g) <|> (f' Generics.:*: g') = (f <|> f') Generics.:*: (g <|> g')
-- TODO: This does the application of '<|>' on the inner type constructors, whereas the original 
-- implementation for the standard classes applies '<|>' on the outer type constructors.
instance (Applicative f g h, AlternativeAlt f' g' h') => AlternativeAlt (f Generics.:.: f') (g Generics.:.: g') (h Generics.:.: h') where
  type AlternativeAltCts (f Generics.:.: f') (g Generics.:.: g') (h Generics.:.: h') = (ApplicativeCts f g h, AlternativeAltCts f' g' h')
  (Generics.Comp1 f) <|> (Generics.Comp1 g) = Generics.Comp1 $ fmap (<|>) f <*> g 
instance AlternativeAlt f g h => AlternativeAlt (Generics.M1 i c f) (Generics.M1 i c g) (Generics.M1 i c h)  where
  type AlternativeAltCts (Generics.M1 i c f) (Generics.M1 i c g) (Generics.M1 i c h) = AlternativeAltCts f g h
  (Generics.M1 f) <|> (Generics.M1 g) = Generics.M1 $ f <|> g























