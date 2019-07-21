module Main where

-- import           Lib
-- import qualified Data.IORef                    as IORef
-- import qualified System.IO                     as IO
import qualified Data.Either                   as E
import           Data.Map.Strict               ((!?))
import qualified Data.Map.Strict               as Map
import qualified Data.Maybe                    as May
import qualified Data.Text.Lazy                as TLazy
import qualified Safe                          as Safe
import qualified System.Console.Haskeline      as HLine
import qualified System.Environment            as Env
import qualified Text.Parsec                   as P
import           Text.ParserCombinators.Parsec ((<|>))
import qualified Text.ParserCombinators.Parsec as PCP
import qualified Text.Pretty.Simple            as PrettyS

type SexyKey = String

type SexyEnv = Map.Map SexyKey Sexy

type SexyReturn = (SexyEnv, Sexy)

data Sexy = NonNorm  (SexyCommand, Sexy, Sexy)
          | Norm     Value

data SexyCommand = Function    (SexyKey, (SexyEnv -> Sexy -> Sexy -> SexyReturn))
                 | SpecialForm (SexyKey, (SexyEnv -> Sexy -> Sexy -> SexyReturn))
                 | UnknownCommand String

data Value = SexyInteger Integer
           | SexyBool    Bool
           | SexyAtom    SexyKey
           | SexyTuple   (Sexy, Sexy)
           | SexyError   String
           | SexyVoid
           | EOF


sexyFuncs :: Map.Map SexyKey (SexyEnv -> Sexy -> Sexy -> SexyReturn)
sexyFuncs = Map.fromList [("+", sexyAdd),
                          ("-", sexySub),
                          ("*", sexyMulti),
                          ("/", sexyDiv),
                          ("%", sexyMod),
                          ("if", sexyIf),
                          ("isError", sexyIsError)]

sexySForms :: Map.Map SexyKey (SexyEnv -> Sexy -> Sexy -> SexyReturn)
sexySForms = Map.fromList [("@", sexyBind),
                           ("do", sexyDo),
                           -- ("d", sexyDeBind),
                           ("`", sexyDeBind),
                           ("tuple", sexyTuple),
                           (".", sexyTuple)]

sexyCommands :: Map.Map SexyKey (SexyEnv -> Sexy -> Sexy -> SexyReturn)
sexyCommands = Map.unions [sexyFuncs, sexySForms]

sexyReserved :: Map.Map SexyKey Sexy
sexyReserved = Map.fromList [("_", Norm SexyVoid),
                             ("T", Norm . SexyBool $ True),
                             ("F", Norm . SexyBool $ False)]

sexyAdd :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyAdd e (Norm (SexyInteger val1)) (Norm (SexyInteger val2)) =
  (e, (Norm . SexyInteger) (val1 + val2))
sexyAdd e arg0 arg1 =
  (e, (Norm . SexyError) $ " failed at addition of " ++ show arg0 ++ " and " ++ show arg1)

sexySub  :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexySub e (Norm (SexyInteger arg0)) (Norm (SexyInteger arg1)) =
  (e, (Norm . SexyInteger) (arg0 - arg1))
sexySub e arg0 arg1 =
  (e, (Norm . SexyError) $ " failed at subtraction of " ++ show arg0 ++ " by " ++ show arg1)

sexyMulti :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyMulti e (Norm (SexyInteger arg0)) (Norm (SexyInteger arg1)) =
  (e, (Norm . SexyInteger) (arg0 * arg1))
sexyMulti e arg0 arg1 =
  (e, (Norm . SexyError) $ " failed at muliplication of " ++ show arg0 ++ " and " ++ show arg1)

sexyDiv :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyDiv e (Norm (SexyInteger arg0)) (Norm (SexyInteger arg1)) =
  (e, (Norm . SexyInteger) (div arg0 arg1))
sexyDiv e arg0 arg1 =
  (e, (Norm . SexyError) $ " failed at division of " ++ show arg0 ++ " by " ++ show arg1)

sexyMod :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyMod e (Norm (SexyInteger arg0)) (Norm (SexyInteger arg1)) =
  (e, (Norm . SexyInteger) (mod arg0 arg1))
sexyMod e arg0 arg1 =
  (e, (Norm . SexyError) $ " failed to yield the remainder from division of " ++ show arg0 ++ " by " ++ show arg1)

sexyIf :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyIf e (Norm (SexyBool bool)) (Norm (SexyTuple (thethen, theelse))) =
  if bool then (evalSexy e thethen) else (evalSexy e theelse)
sexyIf e arg0 arg1 =
  (e, (Norm . SexyError)
    $ "the first arg was " ++ show arg0 ++ " but the second argument were not SexyTuple but " ++ show arg1)

sexyIsError :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyIsError e (Norm SexyVoid) (Norm sexy) =
  (e, Norm $ case sexy of
               SexyError _ -> SexyBool True
               _           -> SexyBool False)
sexyIsError e arg0 arg1 =
  (e, (Norm . SexyError) $ "the first argument is not SexyVoid but " ++ show arg0 ++ "; the second argument is " ++ show arg1)

setSexyVar :: SexyEnv -> SexyKey -> Sexy -> SexyEnv
setSexyVar sexyEnv sexyKey sexyToBeBounded =
  Map.insert sexyKey sexyToBeBounded sexyEnv

defineSexyVar :: SexyEnv -> SexyKey -> Sexy -> Either Sexy SexyEnv
defineSexyVar e sexyKey sexyToBeBounded =
  May.maybe
  (Right $ Map.insert sexyKey sexyToBeBounded e)
  (\x -> Left . Norm . SexyError $ show x ++ " already binded")
  ((Map.unions [sexyReserved , e]) !? sexyKey)

sexyBind :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyBind e arg0@(Norm (SexyError _)) arg1@(Norm (SexyAtom _)) =
  (e, (Norm . SexyError) $ "failed at binding of " ++ show arg0 ++ " by " ++ show arg1)
sexyBind e sexy (Norm (SexyAtom sexyKey)) =
  either (\v -> (e, (Norm . SexyError . show $ v))) (\x -> (x, sexy))
  $ defineSexyVar e sexyKey sexy
sexyBind e arg0 arg1 =
  (e, (Norm . SexyError) $ "failed at binding of " ++ show arg0 ++ " by " ++ show arg1)

sexyDeBind :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyDeBind e (Norm SexyVoid) val@(Norm (SexyAtom sexyKey)) =
  if May.isJust (e !? sexyKey)
  then ((Map.delete sexyKey e), val)
  else (e, (Norm . SexyError $ sexyKey ++ " is not binded"))
sexyDeBind e (Norm SexyVoid) arg1 =
  (e, (Norm . SexyError) $ "failed at deleting binding of by " ++ show arg1)
sexyDeBind e arg0 val@(Norm (SexyAtom _)) =
  (e, (Norm . SexyError)
    $ "failed at deleting binding because the arguments was " ++ show arg0 ++ " and " ++ show val ++ "; the first argument should be SexyVoid")
sexyDeBind e arg0 arg1 =
  (e, (Norm . SexyError)
    $ "failed at deleting binding because the arguments was not SexyVoid and some atom but " ++ show arg0 ++ " and " ++ show arg1)

sexyDo :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyDo e arg0@(NonNorm _) arg1@(NonNorm _) =
  case (evalSexy e arg0) of
    (_, sexy@(Norm (SexyError _))) -> (e, (Norm . SexyError) $ "failed doing " ++ show arg0 ++ " with error " ++ show sexy  ++ " before doing " ++ show arg1)
    (env0, _) -> (evalSexy env0 arg1)
sexyDo e arg0 arg1 =
  (e, (Norm . SexyError)
    $ "failed at doing " ++ show arg0 ++ " and " ++ show arg1)

sexyTuple :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyTuple e (Norm (SexyError err)) sexy1 =
  (e, (Norm . SexyError) $ "can't make tuple with " ++ err ++ " and " ++ show sexy1)
sexyTuple e sexy0 (Norm (SexyError err)) =
  (e, (Norm . SexyError) $ "can't make tuple with " ++ show sexy0 ++ " and " ++ err)
sexyTuple e sexy0 sexy1 =
  (e, (Norm . SexyTuple) (sexy0, sexy1))


sexyUnkownFunc :: SexyEnv -> Sexy -> Sexy -> SexyReturn
sexyUnkownFunc e arg0 arg1 =
  (e, (Norm . SexyError) $ " Unknown function applied to " ++ show arg0 ++ " and " ++ show arg1 ++ ")")

showSexyCommand :: SexyCommand -> String
showSexyCommand (Function ("+", _))    = "(Function: addition)"
showSexyCommand (Function ("-", _))    = "(Function: subtraction)"
showSexyCommand (Function ("*", _))    = "(Function: mutiplication)"
showSexyCommand (Function ("/", _))    = "(Function: division)"
showSexyCommand (Function ("%", _))    = "(Function: modulo)"
showSexyCommand (Function (val, _))    = "(Function: " ++ val ++ ")"
showSexyCommand (SpecialForm ("@", _)) = "(SpecialForm: bind)"
showSexyCommand (SpecialForm ("d", _)) = "(SpecialForm: debind)"
-- showSexyCommand (SpecialForm ("do", _)) = "(SpecialForm: do)"
-- showSexyCommand (SpecialForm ("tuple", _)) = "(SpecialForm: tulpe)"
showSexyCommand (SpecialForm (val, _)) = "(SpecialForm: " ++ val ++ ")"
showSexyCommand (UnknownCommand func)  = "(Unknown function: " ++ func ++ ")"

instance Show SexyCommand where show = showSexyCommand

showSexy :: Sexy -> String
showSexy (NonNorm (sexyfunc, sexy1, sexy2)) =
  showSexyCommand sexyfunc ++ " (Sexy: " ++ showSexy sexy1 ++ ") (Sexy: " ++ showSexy sexy2 ++ ")"
showSexy (Norm types) = showValue types

instance Show Sexy where show = showSexy

showValue :: Value -> String
showValue (SexyInteger integer) = "(SexyInteger: " ++ show integer ++ ")"
showValue (SexyAtom sexyKey)    = "(SexyAtom: " ++ sexyKey ++ ")"
showValue (SexyBool bool)    = "(SexyBool: " ++ show bool ++ ")"
showValue (SexyTuple (sexy0, sexy1)) = "(SexyTuple: (" ++ show sexy0 ++ ", " ++ show sexy1++ "))"
showValue (SexyError err)       = "(SexyError: " ++ err ++ ")"
showValue SexyVoid              = "(SexyVoid: nothing here)"
showValue EOF                   = "(EOF: end of file)"

instance Show Value where show = showValue

parseSexy :: PCP.Parser Sexy
parseSexy = do -- spaces >> (node <|> parsed)
     (do { PCP.eof
         ; return $ Norm EOF})
       <|>
       (PCP.spaces >>
            (parseSexyNonNorm <|> parseSexyNorm))

parseSexyNonNorm :: PCP.Parser Sexy
parseSexyNonNorm = do
  _ <- PCP.char '('
  commKey <- PCP.spaces >>
    do { x <- PCP.anyToken
       ; xs <- ((PCP.letter <|> (PCP.oneOf (foldl1 (++) $ Map.keys sexyCommands)))
                 `PCP.manyTill` (PCP.lookAhead
                                 (P.try
                                  ((PCP.many1 PCP.space)
                                   <|> (P.try (PCP.many1 PCP.digit))
                                   <|> (P.try (PCP.choice $ map PCP.string (Map.keys sexyReserved)))))))
       ; return $ x:xs}
  args <- ((do {x <- PCP.spaces >> parseSexy
               ; PCP.spaces
               ; return x})
            `PCP.manyTill` PCP.char ')')
  let
    sexyComm = case ((Map.lookup commKey sexyFuncs), (Map.lookup commKey sexySForms)) of
                 (Just commKeyhole, _) -> (Function (commKey, commKeyhole))
                 (_, Just commKeyhole) -> (SpecialForm (commKey, commKeyhole))
                 (_, _)    -> (UnknownCommand $ commKey)
    in
    return $ case length args of
               2 -> NonNorm (sexyComm,
                             (May.fromMaybe (Norm . SexyError $ "how can ths be error?") $ Safe.headMay args),
                             (May.fromMaybe (Norm . SexyError $ "how can ths be error?") $ Safe.lastMay args))
               thelength -> (Norm . SexyError)
                            $ show sexyComm ++ " took not 2 arguments but " ++ show thelength
                            ++ (foldl (\xs x -> xs ++ " " ++ x) " arguments:" $ map show args)

parseSexyNorm :: PCP.Parser Sexy
parseSexyNorm = do
  ((Norm . SexyInteger . read) <$> PCP.try (PCP.many1 PCP.digit))
    <|> -- Reserved
    ((\k -> May.fromMaybe (Norm . SexyError $ k ++ " is not reserved")
       (Map.lookup k sexyReserved))
      <$> PCP.try (PCP.choice $ map PCP.string (Map.keys sexyReserved)))
    <|> ((Norm . SexyAtom) <$> PCP.try (PCP.many1 PCP.letter))

evalSexyCommand :: SexyCommand -> (SexyEnv -> Sexy -> Sexy -> SexyReturn)
evalSexyCommand (Function (_, sexyFunc))  = sexyFunc
evalSexyCommand (SpecialForm (_, spForm)) = spForm
evalSexyCommand (UnknownCommand _)        = sexyUnkownFunc

evalSexy :: SexyEnv -> Sexy -> SexyReturn
evalSexy e sexy =
  case sexy of
    NonNorm (func@(Function _), sexy0, sexy1)
      -> (\(x, y, z) -> evalSexyCommand func x y z)
         (case ((evalSexy e sexy0), (evalSexy e sexy1)) of
            ((env0, val0), (env1, val1)) -> ((Map.unions [env1, env0, e]), val0, val1))
    NonNorm (spForm@(SpecialForm _), sexy0, sexy1)
      -> (evalSexyCommand spForm e sexy0 sexy1)
    -- val@(Norm (SexyInteger _))    -> (e, val)
    NonNorm (unknown@(UnknownCommand _), sexy0, sexy1)
      -> (evalSexyCommand unknown e sexy0 sexy1)
    val@(Norm (SexyAtom sexyKey)) ->
      May.maybe (e, val) (evalSexy e) $ Map.lookup sexyKey (Map.unions [e, sexyReserved])
    val -> (e, val)
    -- val@(Norm (SexyTuple _))       -> (e, val)
    -- val@(Norm (SexyError _))      -> (e, val)
    -- val@(Norm SexyVoid)           -> (e, val)
    -- val@(Norm EOF)                -> (e, val)

-- flushStr :: String -> IO ()
-- flushStr str = putStr str >> IO.hFlush IO.stdout

repSexy :: SexyEnv -> Maybe String -> HLine.InputT IO ()
repSexy sexyEnv (Just input) = do
    (\(x, y) -> do {HLine.outputStrLn . TLazy.unpack . PrettyS.pShow $ (x,y)
                   ; replSexy x})
      $ evalSexy sexyEnv
  -- HLine.outputStrLn . TLazy.unpack . PrettyS.pShow
      $ E.either (Norm . SexyError . show) id $ P.parse parseSexy "" input
repSexy _ Nothing = do
  HLine.outputStrLn . TLazy.unpack . PrettyS.pString $ "(SexyFarewell: Bye!)"

replSexy :: SexyEnv -> HLine.InputT IO ()
replSexy sexyEnv = do
  maybeInput <- HLine.getInputLine "(SexyEval:)>> "
  repSexy sexyEnv maybeInput

main :: IO ()
main = do
  args <- Env.getArgs
  HLine.runInputT HLine.defaultSettings $ May.maybe
    (replSexy Map.empty)
    (\x -> repSexy Map.empty (Just x))
    $ Safe.headMay args
