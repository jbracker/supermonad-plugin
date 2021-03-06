
{-# LANGUAGE CPP #-}

-- | Functions and utilities to work with and inspect constraints
--   of the GHC API.
module Control.Super.Plugin.Constraint
  ( -- * Types
    GivenCt, WantedCt, DerivedCt
    -- * Constraint Creation
  , mkDerivedTypeEqCt
  , mkDerivedTypeEqCtOfTypes
  , mkDerivedClassCt
    -- * Constraint inspection
  , isClassConstraint
  , isAnyClassConstraint
  , constraintClassType
  , constraintClassTyArgs
  , constraintClassTyCon
  , constraintPredicateType
  , constraintTopTyCons
  , constraintTopTcVars
  , constraintLocation
  , constraintSourceLocation
  , sortConstraintsByLine
  , constraintTyVars
  ) where

import Data.List ( sortBy )
import qualified Data.Set as Set

import TcRnTypes
  ( Ct(..), CtLoc(..), CtEvidence(..)
  , mkNonCanonical )
import Class ( Class(..) )
import Type
  ( Type, TyVar
  , mkTyVarTy, mkAppTys, mkTyConTy
  , getClassPredTys_maybe
  )
import TyCon ( TyCon )

import Control.Super.Plugin.Collection.Set ( Set )
import qualified Control.Super.Plugin.Collection.Set as S
import Control.Super.Plugin.Wrapper
  ( mkEqualityCtType, constraintSourceLocation )
import Control.Super.Plugin.Utils
  ( collectTopTyCons
  , collectTopTcVars
  , collectTyVars )

-- | Type synonym to label given or derived constraints.
type GivenCt = Ct

-- | Type synonym to label derived constraints.
type DerivedCt = Ct

-- | Type synonym to label wanted constraints.
type WantedCt = Ct

-- -----------------------------------------------------------------------------
-- Constraint Creation
-- -----------------------------------------------------------------------------

-- | Create a derived type equality constraint. The constraint
--   will be located at the location of the given constraints
--   and equate the given types with each other.
mkDerivedTypeEqCtOfTypes :: Ct -> Type -> Type -> Ct
mkDerivedTypeEqCtOfTypes ct ta tb = mkNonCanonical CtDerived
  { ctev_pred = mkEqualityCtType ta tb
  , ctev_loc = constraintLocation ct }

-- | Create a derived type equality constraint. The constraint
--   will be located at the location of the given constraints
--   and equate the given variable with the given type.
mkDerivedTypeEqCt :: Ct -> TyVar -> Type -> Ct
mkDerivedTypeEqCt ct tv = mkDerivedTypeEqCtOfTypes ct (mkTyVarTy tv)

-- | Creates a derived class constraint using the given location
--   as origin. It is the programmers responsibility to supply the
--   correct number of type arguments for the given class.
mkDerivedClassCt :: CtLoc -> Class -> [Type] -> Ct
mkDerivedClassCt loc cls ts = mkNonCanonical CtDerived
  { ctev_pred = mkAppTys (mkTyConTy $ classTyCon cls) ts
  , ctev_loc = loc }

-- -----------------------------------------------------------------------------
-- Constraint Inspection
-- -----------------------------------------------------------------------------

-- | Check if the given constraint is a class constraint of the given class.
isClassConstraint :: Class -> Ct -> Bool
isClassConstraint wantedClass ct =
  case constraintClassType ct of
    Just (cls, _args) -> cls == wantedClass
    _ -> False

-- | Checks if the given constraint belongs to any of the given classes.
isAnyClassConstraint :: [Class] -> Ct -> Bool
isAnyClassConstraint clss ct = or $ fmap (($ ct) . isClassConstraint) clss

-- | Retrieves the class and type arguments of the given
--   type class constraint.
--   Only works if the constraint is a type class constraint, otherwise
--   returns 'Nothing'.
constraintClassType :: Ct -> Maybe (Class, [Type])
constraintClassType ct = case ct of
  CDictCan {} -> Just (cc_class ct, cc_tyargs ct)
  CNonCanonical evdnc -> getClassPredTys_maybe $ ctev_pred evdnc
  _ -> Nothing

-- | Retrieves the arguments of the given constraints.
--   Only works if the given constraint is a type class constraint.
--   See 'constraintClassType'.
constraintClassTyArgs :: Ct -> Maybe [Type]
constraintClassTyArgs = fmap snd . constraintClassType

-- | Retrieves the type constructor of the given type class constraint.
--   See 'constraintClassType'.
constraintClassTyCon :: Ct -> Maybe TyCon
constraintClassTyCon = fmap (classTyCon . fst) . constraintClassType

-- | Collects the type constructors in the arguments of the constraint.
--   Only works if the given constraint is a type class constraint.
--   Only collects those on the top level (See 'collectTopTyCons').
constraintTopTyCons :: Ct -> Set TyCon
constraintTopTyCons ct = maybe S.empty collectTopTyCons $ constraintClassTyArgs ct

-- | Collects the type variables in the arguments of the constraint.
--   Only works if the given constraint is a type class constraint.
--   Only collects those on the top level (See 'collectTopTcVars').
constraintTopTcVars :: Ct -> Set.Set TyVar
constraintTopTcVars ct = maybe Set.empty collectTopTcVars $ constraintClassTyArgs ct

-- | Retrieve the source location the given constraint originated from.
constraintLocation :: Ct -> CtLoc
constraintLocation ct = ctev_loc $ cc_ev ct

-- | Retrieves the type that represents the constraint.
constraintPredicateType :: Ct -> Type
constraintPredicateType ct = ctev_pred $ cc_ev ct

-- | Collect all type variables in the given constraint.
constraintTyVars :: Ct -> Set.Set TyVar
constraintTyVars = collectTyVars . ctev_pred . cc_ev

-- | Sorts constraints by the line of their occurence.
sortConstraintsByLine :: [Ct] -> [Ct]
sortConstraintsByLine = sortBy cmpLine
  where
    cmpLine :: Ct -> Ct -> Ordering
    cmpLine ct1 ct2 = compare (constraintSourceLocation ct1) (constraintSourceLocation ct2)