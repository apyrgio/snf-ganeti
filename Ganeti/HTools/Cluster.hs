{-| Implementation of cluster-wide logic.

This module holds all pure cluster-logic; I\/O related functionality
goes into the "Main" module for the individual binaries.

-}

{-

Copyright (C) 2009 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Ganeti.HTools.Cluster
    (
     -- * Types
      Placement
    , AllocSolution
    , Table(..)
    , Score
    , IMove(..)
    , CStats(..)
    -- * Generic functions
    , totalResources
    -- * First phase functions
    , computeBadItems
    -- * Second phase functions
    , printSolution
    , printSolutionLine
    , formatCmds
    , printNodes
    -- * Balacing functions
    , applyMove
    , checkMove
    , compCV
    , printStats
    -- * IAllocator functions
    , allocateOnSingle
    , allocateOnPair
    , tryAlloc
    , tryReloc
    ) where

import Data.List
import Text.Printf (printf)
import Data.Function
import Control.Monad

import qualified Ganeti.HTools.Container as Container
import qualified Ganeti.HTools.Instance as Instance
import qualified Ganeti.HTools.Node as Node
import Ganeti.HTools.Types
import Ganeti.HTools.Utils

-- * Types

-- | A separate name for the cluster score type.
type Score = Double

-- | The description of an instance placement.
type Placement = (Idx, Ndx, Ndx, Score)

-- | Allocation\/relocation solution.
type AllocSolution = [(OpResult Node.List, Instance.Instance, [Node.Node])]

-- | An instance move definition
data IMove = Failover                -- ^ Failover the instance (f)
           | ReplacePrimary Ndx      -- ^ Replace primary (f, r:np, f)
           | ReplaceSecondary Ndx    -- ^ Replace secondary (r:ns)
           | ReplaceAndFailover Ndx  -- ^ Replace secondary, failover (r:np, f)
           | FailoverAndReplace Ndx  -- ^ Failover, replace secondary (f, r:ns)
             deriving (Show)

-- | The complete state for the balancing solution
data Table = Table Node.List Instance.List Score [Placement]
             deriving (Show)

data CStats = CStats { cs_fmem :: Int    -- ^ Cluster free mem
                     , cs_fdsk :: Int    -- ^ Cluster free disk
                     , cs_amem :: Int    -- ^ Cluster allocatable mem
                     , cs_adsk :: Int    -- ^ Cluster allocatable disk
                     , cs_acpu :: Int    -- ^ Cluster allocatable cpus
                     , cs_mmem :: Int    -- ^ Max node allocatable mem
                     , cs_mdsk :: Int    -- ^ Max node allocatable disk
                     , cs_mcpu :: Int    -- ^ Max node allocatable cpu
                     , cs_imem :: Int    -- ^ Instance used mem
                     , cs_idsk :: Int    -- ^ Instance used disk
                     , cs_icpu :: Int    -- ^ Instance used cpu
                     , cs_tmem :: Double -- ^ Cluster total mem
                     , cs_tdsk :: Double -- ^ Cluster total disk
                     , cs_tcpu :: Double -- ^ Cluster total cpus
                     , cs_xmem :: Int    -- ^ Unnacounted for mem
                     , cs_nmem :: Int    -- ^ Node own memory
                     , cs_score :: Score -- ^ The cluster score
                     , cs_ninst :: Int   -- ^ The total number of instances
                     }

-- * Utility functions

-- | Verifies the N+1 status and return the affected nodes.
verifyN1 :: [Node.Node] -> [Node.Node]
verifyN1 = filter Node.failN1

{-| Computes the pair of bad nodes and instances.

The bad node list is computed via a simple 'verifyN1' check, and the
bad instance list is the list of primary and secondary instances of
those nodes.

-}
computeBadItems :: Node.List -> Instance.List ->
                   ([Node.Node], [Instance.Instance])
computeBadItems nl il =
  let bad_nodes = verifyN1 $ getOnline nl
      bad_instances = map (\idx -> Container.find idx il) .
                      sort . nub $
                      concatMap (\ n -> Node.slist n ++ Node.plist n) bad_nodes
  in
    (bad_nodes, bad_instances)

emptyCStats :: CStats
emptyCStats = CStats { cs_fmem = 0
                     , cs_fdsk = 0
                     , cs_amem = 0
                     , cs_adsk = 0
                     , cs_acpu = 0
                     , cs_mmem = 0
                     , cs_mdsk = 0
                     , cs_mcpu = 0
                     , cs_imem = 0
                     , cs_idsk = 0
                     , cs_icpu = 0
                     , cs_tmem = 0
                     , cs_tdsk = 0
                     , cs_tcpu = 0
                     , cs_xmem = 0
                     , cs_nmem = 0
                     , cs_score = 0
                     , cs_ninst = 0
                     }

updateCStats :: CStats -> Node.Node -> CStats
updateCStats cs node =
    let CStats { cs_fmem = x_fmem, cs_fdsk = x_fdsk,
                 cs_amem = x_amem, cs_acpu = x_acpu, cs_adsk = x_adsk,
                 cs_mmem = x_mmem, cs_mdsk = x_mdsk, cs_mcpu = x_mcpu,
                 cs_imem = x_imem, cs_idsk = x_idsk, cs_icpu = x_icpu,
                 cs_tmem = x_tmem, cs_tdsk = x_tdsk, cs_tcpu = x_tcpu,
                 cs_xmem = x_xmem, cs_nmem = x_nmem, cs_ninst = x_ninst
               }
            = cs
        inc_amem = Node.f_mem node - Node.r_mem node
        inc_amem' = if inc_amem > 0 then inc_amem else 0
        inc_adsk = Node.availDisk node
        inc_imem = truncate (Node.t_mem node) - Node.n_mem node
                   - Node.x_mem node - Node.f_mem node
        inc_icpu = Node.u_cpu node
        inc_idsk = truncate (Node.t_dsk node) - Node.f_dsk node

    in cs { cs_fmem = x_fmem + Node.f_mem node
          , cs_fdsk = x_fdsk + Node.f_dsk node
          , cs_amem = x_amem + inc_amem'
          , cs_adsk = x_adsk + inc_adsk
          , cs_acpu = x_acpu
          , cs_mmem = max x_mmem inc_amem'
          , cs_mdsk = max x_mdsk inc_adsk
          , cs_mcpu = x_mcpu
          , cs_imem = x_imem + inc_imem
          , cs_idsk = x_idsk + inc_idsk
          , cs_icpu = x_icpu + inc_icpu
          , cs_tmem = x_tmem + Node.t_mem node
          , cs_tdsk = x_tdsk + Node.t_dsk node
          , cs_tcpu = x_tcpu + Node.t_cpu node
          , cs_xmem = x_xmem + Node.x_mem node
          , cs_nmem = x_nmem + Node.n_mem node
          , cs_ninst = x_ninst + length (Node.plist node)
          }

-- | Compute the total free disk and memory in the cluster.
totalResources :: Node.List -> CStats
totalResources nl =
    let cs = foldl' updateCStats emptyCStats . Container.elems $ nl
    in cs { cs_score = compCV nl }

-- | Compute the mem and disk covariance.
compDetailedCV :: Node.List -> (Double, Double, Double, Double, Double, Double)
compDetailedCV nl =
    let
        all_nodes = Container.elems nl
        (offline, nodes) = partition Node.offline all_nodes
        mem_l = map Node.p_mem nodes
        dsk_l = map Node.p_dsk nodes
        mem_cv = varianceCoeff mem_l
        dsk_cv = varianceCoeff dsk_l
        n1_l = length $ filter Node.failN1 nodes
        n1_score = fromIntegral n1_l /
                   fromIntegral (length nodes)::Double
        res_l = map Node.p_rem nodes
        res_cv = varianceCoeff res_l
        offline_inst = sum . map (\n -> (length . Node.plist $ n) +
                                        (length . Node.slist $ n)) $ offline
        online_inst = sum . map (\n -> (length . Node.plist $ n) +
                                       (length . Node.slist $ n)) $ nodes
        off_score = if offline_inst == 0
                    then 0::Double
                    else fromIntegral offline_inst /
                         fromIntegral (offline_inst + online_inst)::Double
        cpu_l = map Node.p_cpu nodes
        cpu_cv = varianceCoeff cpu_l
    in (mem_cv, dsk_cv, n1_score, res_cv, off_score, cpu_cv)

-- | Compute the /total/ variance.
compCV :: Node.List -> Double
compCV nl =
    let (mem_cv, dsk_cv, n1_score, res_cv, off_score, cpu_cv) =
            compDetailedCV nl
    in mem_cv + dsk_cv + n1_score + res_cv + off_score + cpu_cv

-- | Compute online nodes from a Node.List
getOnline :: Node.List -> [Node.Node]
getOnline = filter (not . Node.offline) . Container.elems

-- * hbal functions

-- | Compute best table. Note that the ordering of the arguments is important.
compareTables :: Table -> Table -> Table
compareTables a@(Table _ _ a_cv _) b@(Table _ _ b_cv _ ) =
    if a_cv > b_cv then b else a

-- | Applies an instance move to a given node list and instance.
applyMove :: Node.List -> Instance.Instance
          -> IMove -> (OpResult Node.List, Instance.Instance, Ndx, Ndx)
-- Failover (f)
applyMove nl inst Failover =
    let old_pdx = Instance.pnode inst
        old_sdx = Instance.snode inst
        old_p = Container.find old_pdx nl
        old_s = Container.find old_sdx nl
        int_p = Node.removePri old_p inst
        int_s = Node.removeSec old_s inst
        new_nl = do -- Maybe monad
          new_p <- Node.addPri int_s inst
          new_s <- Node.addSec int_p inst old_sdx
          return $ Container.addTwo old_pdx new_s old_sdx new_p nl
    in (new_nl, Instance.setBoth inst old_sdx old_pdx, old_sdx, old_pdx)

-- Replace the primary (f:, r:np, f)
applyMove nl inst (ReplacePrimary new_pdx) =
    let old_pdx = Instance.pnode inst
        old_sdx = Instance.snode inst
        old_p = Container.find old_pdx nl
        old_s = Container.find old_sdx nl
        tgt_n = Container.find new_pdx nl
        int_p = Node.removePri old_p inst
        int_s = Node.removeSec old_s inst
        new_nl = do -- Maybe monad
          -- check that the current secondary can host the instance
          -- during the migration
          tmp_s <- Node.addPri int_s inst
          let tmp_s' = Node.removePri tmp_s inst
          new_p <- Node.addPri tgt_n inst
          new_s <- Node.addSec tmp_s' inst new_pdx
          return . Container.add new_pdx new_p $
                 Container.addTwo old_pdx int_p old_sdx new_s nl
    in (new_nl, Instance.setPri inst new_pdx, new_pdx, old_sdx)

-- Replace the secondary (r:ns)
applyMove nl inst (ReplaceSecondary new_sdx) =
    let old_pdx = Instance.pnode inst
        old_sdx = Instance.snode inst
        old_s = Container.find old_sdx nl
        tgt_n = Container.find new_sdx nl
        int_s = Node.removeSec old_s inst
        new_nl = Node.addSec tgt_n inst old_pdx >>=
                 \new_s -> return $ Container.addTwo new_sdx
                           new_s old_sdx int_s nl
    in (new_nl, Instance.setSec inst new_sdx, old_pdx, new_sdx)

-- Replace the secondary and failover (r:np, f)
applyMove nl inst (ReplaceAndFailover new_pdx) =
    let old_pdx = Instance.pnode inst
        old_sdx = Instance.snode inst
        old_p = Container.find old_pdx nl
        old_s = Container.find old_sdx nl
        tgt_n = Container.find new_pdx nl
        int_p = Node.removePri old_p inst
        int_s = Node.removeSec old_s inst
        new_nl = do -- Maybe monad
          new_p <- Node.addPri tgt_n inst
          new_s <- Node.addSec int_p inst new_pdx
          return . Container.add new_pdx new_p $
                 Container.addTwo old_pdx new_s old_sdx int_s nl
    in (new_nl, Instance.setBoth inst new_pdx old_pdx, new_pdx, old_pdx)

-- Failver and replace the secondary (f, r:ns)
applyMove nl inst (FailoverAndReplace new_sdx) =
    let old_pdx = Instance.pnode inst
        old_sdx = Instance.snode inst
        old_p = Container.find old_pdx nl
        old_s = Container.find old_sdx nl
        tgt_n = Container.find new_sdx nl
        int_p = Node.removePri old_p inst
        int_s = Node.removeSec old_s inst
        new_nl = do -- Maybe monad
          new_p <- Node.addPri int_s inst
          new_s <- Node.addSec tgt_n inst old_sdx
          return . Container.add new_sdx new_s $
                 Container.addTwo old_sdx new_p old_pdx int_p nl
    in (new_nl, Instance.setBoth inst old_sdx new_sdx, old_sdx, new_sdx)

-- | Tries to allocate an instance on one given node.
allocateOnSingle :: Node.List -> Instance.Instance -> Node.Node
                 -> (OpResult Node.List, Instance.Instance)
allocateOnSingle nl inst p =
    let new_pdx = Node.idx p
        new_nl = Node.addPri p inst >>= \new_p ->
                 return $ Container.add new_pdx new_p nl
    in (new_nl, Instance.setBoth inst new_pdx Node.noSecondary)

-- | Tries to allocate an instance on a given pair of nodes.
allocateOnPair :: Node.List -> Instance.Instance -> Node.Node -> Node.Node
               -> (OpResult Node.List, Instance.Instance)
allocateOnPair nl inst tgt_p tgt_s =
    let new_pdx = Node.idx tgt_p
        new_sdx = Node.idx tgt_s
        new_nl = do -- Maybe monad
          new_p <- Node.addPri tgt_p inst
          new_s <- Node.addSec tgt_s inst new_pdx
          return $ Container.addTwo new_pdx new_p new_sdx new_s nl
    in (new_nl, Instance.setBoth inst new_pdx new_sdx)

-- | Tries to perform an instance move and returns the best table
-- between the original one and the new one.
checkSingleStep :: Table -- ^ The original table
                -> Instance.Instance -- ^ The instance to move
                -> Table -- ^ The current best table
                -> IMove -- ^ The move to apply
                -> Table -- ^ The final best table
checkSingleStep ini_tbl target cur_tbl move =
    let
        Table ini_nl ini_il _ ini_plc = ini_tbl
        (tmp_nl, new_inst, pri_idx, sec_idx) = applyMove ini_nl target move
    in
      case tmp_nl of
        OpFail _ -> cur_tbl
        OpGood upd_nl ->
            let tgt_idx = Instance.idx target
                upd_cvar = compCV upd_nl
                upd_il = Container.add tgt_idx new_inst ini_il
                upd_plc = (tgt_idx, pri_idx, sec_idx, upd_cvar):ini_plc
                upd_tbl = Table upd_nl upd_il upd_cvar upd_plc
            in
              compareTables cur_tbl upd_tbl

-- | Given the status of the current secondary as a valid new node
-- and the current candidate target node,
-- generate the possible moves for a instance.
possibleMoves :: Bool -> Ndx -> [IMove]
possibleMoves True tdx =
    [ReplaceSecondary tdx,
     ReplaceAndFailover tdx,
     ReplacePrimary tdx,
     FailoverAndReplace tdx]

possibleMoves False tdx =
    [ReplaceSecondary tdx,
     ReplaceAndFailover tdx]

-- | Compute the best move for a given instance.
checkInstanceMove :: [Ndx]             -- Allowed target node indices
                  -> Table             -- Original table
                  -> Instance.Instance -- Instance to move
                  -> Table             -- Best new table for this instance
checkInstanceMove nodes_idx ini_tbl target =
    let
        opdx = Instance.pnode target
        osdx = Instance.snode target
        nodes = filter (\idx -> idx /= opdx && idx /= osdx) nodes_idx
        use_secondary = elem osdx nodes_idx
        aft_failover = if use_secondary -- if allowed to failover
                       then checkSingleStep ini_tbl target ini_tbl Failover
                       else ini_tbl
        all_moves = concatMap (possibleMoves use_secondary) nodes
    in
      -- iterate over the possible nodes for this instance
      foldl' (checkSingleStep ini_tbl target) aft_failover all_moves

-- | Compute the best next move.
checkMove :: [Ndx]               -- ^ Allowed target node indices
          -> Table               -- ^ The current solution
          -> [Instance.Instance] -- ^ List of instances still to move
          -> Table               -- ^ The new solution
checkMove nodes_idx ini_tbl victims =
    let Table _ _ _ ini_plc = ini_tbl
        -- iterate over all instances, computing the best move
        best_tbl =
            foldl'
            (\ step_tbl elem ->
                 if Instance.snode elem == Node.noSecondary then step_tbl
                    else compareTables step_tbl $
                         checkInstanceMove nodes_idx ini_tbl elem)
            ini_tbl victims
        Table _ _ _ best_plc = best_tbl
    in
      if length best_plc == length ini_plc then -- no advancement
          ini_tbl
      else
          best_tbl

-- * Alocation functions

-- | Try to allocate an instance on the cluster.
tryAlloc :: (Monad m) =>
            Node.List         -- ^ The node list
         -> Instance.List     -- ^ The instance list
         -> Instance.Instance -- ^ The instance to allocate
         -> Int               -- ^ Required number of nodes
         -> m AllocSolution   -- ^ Possible solution list
tryAlloc nl _ inst 2 =
    let all_nodes = getOnline nl
        all_pairs = liftM2 (,) all_nodes all_nodes
        ok_pairs = filter (\(x, y) -> Node.idx x /= Node.idx y) all_pairs
        sols = map (\(p, s) -> let (mnl, i) = allocateOnPair nl inst p s
                               in (mnl, i, [p, s]))
               ok_pairs
    in return sols

tryAlloc nl _ inst 1 =
    let all_nodes = getOnline nl
        sols = map (\p -> let (mnl, i) = allocateOnSingle nl inst p
                          in (mnl, i, [p]))
               all_nodes
    in return sols

tryAlloc _ _ _ reqn = fail $ "Unsupported number of alllocation \
                             \destinations required (" ++ show reqn ++
                                               "), only two supported"

-- | Try to allocate an instance on the cluster.
tryReloc :: (Monad m) =>
            Node.List       -- ^ The node list
         -> Instance.List   -- ^ The instance list
         -> Idx             -- ^ The index of the instance to move
         -> Int             -- ^ The numver of nodes required
         -> [Ndx]           -- ^ Nodes which should not be used
         -> m AllocSolution -- ^ Solution list
tryReloc nl il xid 1 ex_idx =
    let all_nodes = getOnline nl
        inst = Container.find xid il
        ex_idx' = Instance.pnode inst:ex_idx
        valid_nodes = filter (not . flip elem ex_idx' . Node.idx) all_nodes
        valid_idxes = map Node.idx valid_nodes
        sols1 = map (\x -> let (mnl, i, _, _) =
                                   applyMove nl inst (ReplaceSecondary x)
                           in (mnl, i, [Container.find x nl])
                     ) valid_idxes
    in return sols1

tryReloc _ _ _ reqn _  = fail $ "Unsupported number of relocation \
                                \destinations required (" ++ show reqn ++
                                                  "), only one supported"

-- * Formatting functions

-- | Given the original and final nodes, computes the relocation description.
computeMoves :: String -- ^ The instance name
             -> String -- ^ Original primary
             -> String -- ^ Original secondary
             -> String -- ^ New primary
             -> String -- ^ New secondary
             -> (String, [String])
                -- ^ Tuple of moves and commands list; moves is containing
                -- either @/f/@ for failover or @/r:name/@ for replace
                -- secondary, while the command list holds gnt-instance
                -- commands (without that prefix), e.g \"@failover instance1@\"
computeMoves i a b c d
    -- same primary
    | c == a =
        if d == b
        then {- Same sec??! -} ("-", [])
        else {- Change of secondary -}
            (printf "r:%s" d, [rep d])
    -- failover and ...
    | c == b =
        if d == a
        then {- that's all -} ("f", [mig])
        else (printf "f r:%s" d, [mig, rep d])
    -- ... and keep primary as secondary
    | d == a =
        (printf "r:%s f" c, [rep c, mig])
    -- ... keep same secondary
    | d == b =
        (printf "f r:%s f" c, [mig, rep c, mig])
    -- nothing in common -
    | otherwise =
        (printf "r:%s f r:%s" c d, [rep c, mig, rep d])
    where mig = printf "migrate -f %s" i::String
          rep n = printf "replace-disks -n %s %s" n i

-- | Converts a placement to string format.
printSolutionLine :: Node.List     -- ^ The node list
                  -> Instance.List -- ^ The instance list
                  -> Int           -- ^ Maximum node name length
                  -> Int           -- ^ Maximum instance name length
                  -> Placement     -- ^ The current placement
                  -> Int           -- ^ The index of the placement in
                                   -- the solution
                  -> (String, [String])
printSolutionLine nl il nmlen imlen plc pos =
    let
        pmlen = (2*nmlen + 1)
        (i, p, s, c) = plc
        inst = Container.find i il
        inam = Instance.name inst
        npri = Container.nameOf nl p
        nsec = Container.nameOf nl s
        opri = Container.nameOf nl $ Instance.pnode inst
        osec = Container.nameOf nl $ Instance.snode inst
        (moves, cmds) =  computeMoves inam opri osec npri nsec
        ostr = printf "%s:%s" opri osec::String
        nstr = printf "%s:%s" npri nsec::String
    in
      (printf "  %3d. %-*s %-*s => %-*s %.8f a=%s"
       pos imlen inam pmlen ostr
       pmlen nstr c moves,
       cmds)

-- | Given a list of commands, prefix them with @gnt-instance@ and
-- also beautify the display a little.
formatCmds :: [[String]] -> String
formatCmds =
    unlines .
    concatMap (\(a, b) ->
               printf "echo step %d" (a::Int):
               printf "check":
               map ("gnt-instance " ++) b
              ) .
    zip [1..]

-- | Converts a solution to string format.
printSolution :: Node.List
              -> Instance.List
              -> [Placement]
              -> ([String], [[String]])
printSolution nl il sol =
    let
        nmlen = Container.maxNameLen nl
        imlen = Container.maxNameLen il
    in
      unzip $ zipWith (printSolutionLine nl il nmlen imlen) sol [1..]

-- | Print the node list.
printNodes :: Node.List -> String
printNodes nl =
    let snl = sortBy (compare `on` Node.idx) (Container.elems nl)
        m_name = maximum . map (length . Node.name) $ snl
        helper = Node.list m_name
        header = printf
                 "%2s %-*s %5s %5s %5s %5s %5s %5s %5s %5s %4s %4s \
                 \%3s %3s %6s %6s %5s"
                 " F" m_name "Name"
                 "t_mem" "n_mem" "i_mem" "x_mem" "f_mem" "r_mem"
                 "t_dsk" "f_dsk" "pcpu" "vcpu"
                 "pri" "sec" "p_fmem" "p_fdsk" "r_cpu"::String
    in unlines (header:map helper snl)

-- | Shows statistics for a given node list.
printStats :: Node.List -> String
printStats nl =
    let (mem_cv, dsk_cv, n1_score, res_cv, off_score, cpu_cv) =
            compDetailedCV nl
    in printf "f_mem=%.8f, r_mem=%.8f, f_dsk=%.8f, n1=%.3f, \
              \uf=%.3f, r_cpu=%.3f"
       mem_cv res_cv dsk_cv n1_score off_score cpu_cv
