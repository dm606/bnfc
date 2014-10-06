{-
    BNF Converter: Happy Generator
    Copyright (C) 2004  Author:  Markus Forberg, Aarne Ranta

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

module BNFC.Backend.HaskellProfile.CFtoHappyProfile
       (
       cf2HappyProfileS
       )
        where

import BNFC.CF
--import Lexer
import Data.List (intersperse)

-- Type declarations

type Rules       = [(NonTerminal,[(Pattern,Action)])]
type Pattern     = String
type Action      = String
type MetaVar     = String

-- default naming

tokenName   = "Token"

-- The main function, that given a CF and a CFCat to parse according to,
-- generates a happy module.
cf2HappyProfileS :: String -> String -> String -> String -> CFP -> String
cf2HappyProfileS = cf2Happy

cf2Happy :: String -> String -> String -> String -> CFP -> String
cf2Happy name absName lexName errName cf
 = unlines
    [header name absName lexName errName,
     declarations (allEntryPoints cf),
     tokens (symbols cf ++ reservedWords cf),
     specialToks cf,
     delimiter,
     specialRules cf,
     prRules (rulesForHappy cf),
     finalize cf]

-- construct the header.
header :: String -> String -> String -> String -> String
header modName _ lexName errName = unlines
         ["-- This Happy file was machine-generated by the BNF converter",
	  "{",
          "module " ++ modName ++ " where",
----          "import " ++ absName,
          "import Trees",
          "import " ++ lexName,
          "import " ++ errName,
          "}"
         ]


-- The declarations of a happy file.
declarations :: [Cat] -> String
declarations ns = unlines
                 [generateP ns,
                  "%monad { Err } { thenM } { returnM }",
                  "%tokentype { " ++ tokenName ++ " }"]
   where generateP []     = []
	 generateP (n:ns) = concat ["%name p",n'," ",n',"\n",generateP ns]
                               where n' = identCat n

-- The useless delimiter symbol.
delimiter :: String
delimiter = "\n%%\n"

-- Generate the list of tokens and their identifiers.
tokens :: [String] -> String
tokens toks = "%token \n" ++ prTokens toks
 where prTokens []     = []
       prTokens (t:tk) = " " ++ (convert t) ++
                         " { " ++ oneTok t ++ " }\n" ++
                         prTokens tk
       oneTok t = "PT _ (TS " ++ show t ++ ")"

-- Happy doesn't allow characters such as åäö to occur in the happy file. This
-- is however not a restriction, just a naming paradigm in the happy source file.
convert :: String -> String
convert "\\" = concat ['\'':"\\\\","\'"]
convert xs   = concat ['\'':(escape xs),"\'"]
  where escape [] = []
	escape ('\'':xs) = '\\':'\'':escape xs
	escape (x:xs) = x:escape xs

rulesForHappy :: CFP -> Rules
rulesForHappy cf = map mkOne $ ruleGroupsP cf where
  mkOne (cat,rules) = constructRule cf rules cat

-- For every non-terminal, we construct a set of rules. A rule is a sequence of
-- terminals and non-terminals, and an action to be performed
-- As an optimization, a pair of list rules [C] ::= "" | C k [C]
-- is left-recursivized into [C] ::= "" | [C] C k.
-- This could be generalized to cover other forms of list rules.
constructRule :: CFP -> [RuleP] -> NonTerminal -> (NonTerminal,[(Pattern,Action)])
constructRule cf rules nt = (nt,[(p,generateAction nt (revF b r) m) |
     r0 <- rules,
     let (b,r) = if isConsFun (funRuleP r0) && elem (valCat r0) revs
                   then (True,revSepListRule r0)
                 else (False,r0),
     let (p,m) = generatePatterns cf r])
 where
   ---- left rec optimization does not work yet
   revF _ r = ---- if b then ("flip " ++ funRuleP r) else (funRuleP r)
              funRule r
   revs = reversibleCats cf

-- Generates a string containing the semantic action.
-- An action can for example be: Sum $1 $2, that is, construct an AST
-- with the constructor Sum applied to the two metavariables $1 and $2.
generateAction :: NonTerminal -> FunP -> [MetaVar] -> Action
generateAction _ (_,(h,p)) ms = unwords (if isCoercion h then args else fun ++ mss)
  where
    fun = ["mkFunTree",show h,show p]
    mss = ["["] ++ intersperse "," ms ++ ["]"]
    args = intersperse "," ms

-- Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal

generatePatterns :: CFP -> RuleP -> (Pattern,[MetaVar])
generatePatterns cf r = case rhsRule r of
  []  -> ("{- empty -}",[])
  its -> (unwords (map mkIt its), metas its)
 where
   mkIt i = case i of
     Left c -> identCat c
     Right s -> convert s
   metas its = [revIf c ('$': show i) | (i,Left c) <- zip [1 ::Int ..] its]
   revIf c m = if (not (isConsFun (funRuleP r)) && elem c revs)
                 then ("(reverse " ++ m ++ ")")
               else m  -- no reversal in the left-recursive Cons rule itself
   revs = reversibleCats cf

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.

prRules :: Rules -> String
prRules = unlines . map prOne
  where
    prOne (_,[]) = [] -- nt has only internal use
    prOne (nt,(p,a):ls) =
      unwords [nt', "::", "{", "CFTree", "}\n" ++
               nt', ":" , p, "{", a, "}", '\n' : pr ls] ++ "\n"
     where
       nt' = identCat nt
       pr [] = []
       pr ((p,a):ls) =
         unlines [(concat $ intersperse " " ["  |", p, "{", a , "}"])] ++ pr ls

-- Finally, some haskell code.

finalize :: CFP -> String
finalize _ = unlines
   [
     "{",
     "\nreturnM :: a -> Err a",
     "returnM = return",
     "\nthenM :: Err a -> (a -> Err b) -> Err b",
     "thenM = (>>=)",
     "\nhappyError :: [" ++ tokenName ++ "] -> Err a",
     "happyError ts =",
     "  Bad $ \"syntax error at \" ++ tokenPos ts ++ " ++
         "if null ts then [] else " ++
         "(\" before \" ++ " ++ "unwords (map prToken (take 4 ts)))",
     "\nmyLexer = tokens",
     "}"
   ]

-- aarne's modifs 8/1/2002:
-- Markus's modifs 11/02/2002

-- GF literals
specialToks :: CFP -> String
specialToks cf = unlines $
		 (map aux (literals cf))
 where aux cat =
        case cat of
          Cat "Ident"  -> "L_ident  { PT _ (TV $$) }"
          Cat "String" -> "L_quoted { PT _ (TL $$) }"
          Cat "Integer" -> "L_integ  { PT _ (TI $$) }"
          Cat "Double" -> "L_doubl  { PT _ (TD $$) }"
          Cat "Char"   -> "L_charac { PT _ (TC $$) }"
          own      -> "L_" ++ show own ++ " { PT _ (T_" ++ show own ++ " " ++ posn ++ ") }"
         where
           posn = if isPositionCat cf cat then "_" else "$$"

specialRules :: CFP -> String
specialRules cf = unlines $
                  map aux (literals cf)
 where
   aux cat =
     case cat of
         Cat "Ident"   -> "Ident   : L_ident  { mkAtTree (AV (Ident $1)) }"
	 Cat "String"  -> "String  : L_quoted { mkAtTree (AS $1) }"
	 Cat "Integer" -> "Integer : L_integ  { mkAtTree (AI ((read $1) :: Integer)) }"
	 Cat "Double"  -> "Double  : L_doubl  { (read $1) :: Double }" ----
	 Cat "Char"    -> "Char    : L_charac { (read $1) :: Char }"   ----
	 own       -> show own ++ "    : L_" ++ show own ++ " { " ++ show own ++ " ("++ posn ++ "$1)}"
      where
         posn = if isPositionCat cf cat then "mkPosToken " else ""
