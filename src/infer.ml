(******************************************************************************)
(*                                                                            *)
(*                                   Menhir                                   *)
(*                                                                            *)
(*                       François Pottier, Inria Paris                        *)
(*              Yann Régis-Gianas, PPS, Université Paris Diderot              *)
(*                                                                            *)
(*  Copyright Inria. All rights reserved. This file is distributed under the  *)
(*  terms of the GNU General Public License version 2, as described in the    *)
(*  file LICENSE.                                                             *)
(*                                                                            *)
(******************************************************************************)

open Syntax
open Stretch
open BasicSyntax
open IL
open CodeBits
open TokenType

(* ------------------------------------------------------------------------- *)
(* Naming conventions. *)

(* The type variable associated with a nonterminal symbol. Its name begins
   with a prefix which ensures that it begins with a lowercase letter and
   cannot clash with OCaml keywords. *)

let ntvar symbol =
  Printf.sprintf "tv_%s" (Misc.normalize symbol)

(* The term variable associated with a nonterminal symbol. Its name begins
   with a prefix which ensures that it begins with a lowercase letter and
   cannot clash with OCaml keywords. *)

let encode symbol =
  Printf.sprintf "xv_%s" (Misc.normalize symbol)

let decode s =
  let n = String.length s in
  if not (n >= 3 && String.sub s 0 3 = "xv_") then
    Lexmli.fail();
  String.sub s 3 (n - 3)

(* The name of the temporary file. *)

let base =
  Settings.base

let mlname =
  base ^ ".ml"

let mliname =
  base ^ ".mli"

(* ------------------------------------------------------------------------- *)
(* Code production. *)

(* [nttype nt] is the type of the nonterminal [nt], as currently
   known. *)

let nttype grammar nt =
   try
     TypTextual (StringMap.find nt grammar.types)
   with Not_found ->
     TypVar (ntvar nt)

(* [is_standard] determines whether a branch derives from a standard
   library definition. The method, based on a file name, is somewhat
   fragile. *)

let is_standard branch =
  List.for_all (fun x -> x = Settings.stdlib_filename) (Action.filenames branch.action)

(* [actiondef] turns a branch into a function definition. *)

(* The names and types of the conventional internal variables that
   correspond to keywords ($startpos,etc.) are hardwired in this
   code. It would be nice if these conventions were more clearly
   isolated and perhaps moved to the [Action] or [Keyword] module. *)

let actiondef grammar symbol branch =

  (* Construct a list of the semantic action's formal parameters that
     depend on the production's right-hand side. *)

  let formals =
    List.fold_left (fun formals producer ->
      let symbol = producer_symbol producer
      and id = producer_identifier producer in
      let startp, endp, starto, endo, loc =
        Printf.sprintf "_startpos_%s_" id,
        Printf.sprintf "_endpos_%s_" id,
        Printf.sprintf "_startofs_%s_" id,
        Printf.sprintf "_endofs_%s_" id,
        Printf.sprintf "_loc_%s_" id
      in
      let t =
        try
          let props = StringMap.find symbol grammar.tokens in
          (* Symbol is a terminal. *)
          match props.tk_ocamltype with
          | None ->
              tunit
          | Some ocamltype ->
              TypTextual ocamltype
        with Not_found ->
          (* Symbol is a nonterminal. *)
          nttype grammar symbol
      in
      PAnnot (PVar id, t) ::
      PAnnot (PVar startp, tposition) ::
      PAnnot (PVar endp, tposition) ::
      PAnnot (PVar starto, tint) ::
      PAnnot (PVar endo, tint) ::
      PAnnot (PVar loc, tlocation) ::
      formals
    ) [] branch.producers
  in

  (* Extend the list with parameters that do not depend on the
     right-hand side. *)

  let formals =
    PAnnot (PVar "_eRR", texn) ::
    PAnnot (PVar "_startpos", tposition) ::
    PAnnot (PVar "_endpos", tposition) ::
    PAnnot (PVar "_endpos__0_", tposition) ::
    PAnnot (PVar "_symbolstartpos", tposition) ::
    PAnnot (PVar "_startofs", tint) ::
    PAnnot (PVar "_endofs", tint) ::
    PAnnot (PVar "_endofs__0_", tint) ::
    PAnnot (PVar "_symbolstartofs", tint) ::
    PAnnot (PVar "_sloc", tlocation) ::
    PAnnot (PVar "_loc", tlocation) ::
    formals
  in

  (* Construct a function definition out of the above bindings and the
     semantic action. *)

  let body =
    EAnnot (
      Action.to_il_expr branch.action,
      type2scheme (nttype grammar symbol)
    )
  in

  match formals with
  | [] ->
      body
  | _ ->
      EFun (formals, body)

(* [program] turns an entire grammar into a test program. *)

let program grammar =

  (* Turn the grammar into a bunch of function definitions. Grammar
     productions that derive from the standard library are reflected
     first, so that type errors are not reported in them. *)

  let bindings1, bindings2 =
    StringMap.fold (fun symbol rule (bindings1, bindings2) ->
      List.fold_left (fun (bindings1, bindings2) branch ->
        if is_standard branch then
          (PWildcard, actiondef grammar symbol branch) :: bindings1, bindings2
        else
          bindings1, (PWildcard, actiondef grammar symbol branch) :: bindings2
      ) (bindings1, bindings2) rule.branches
    ) grammar.rules ([], [])
  in

  (* Create entry points whose types are the unknowns that we are
     looking for. *)

  let ps, ts =
    StringMap.fold (fun symbol _ (ps, ts) ->
      PVar (encode (Misc.normalize symbol)) :: ps,
      nttype grammar symbol :: ts
    ) grammar.rules ([], [])
  in

  let def = {
    valpublic = true;
    valpat = PTuple ps;
    valval = ELet (bindings1 @ bindings2, EAnnot (bottom, type2scheme (TypTuple ts)))
  }
  in

  (* Insert markers to delimit the part of the file that we are
     interested in. These markers are recognized by [Lexmli]. This
     helps skip the values, types, exceptions, etc. that might be
     defined by the prologue or postlogue. *)

  let begindef = {
    valpublic = true;
    valpat = PVar "menhir_begin_marker";
    valval = EIntConst 0
  }
  and enddef = {
    valpublic = true;
    valpat = PVar "menhir_end_marker";
    valval = EIntConst 0
  } in

  (* Issue the test program. We include the definition of the type of
     tokens, because, in principle, the semantic actions may refer to
     it or to its data constructors. *)

  [ SIFunctor (grammar.parameters,
    interface_to_structure (tokentypedef grammar) @
    SIStretch grammar.preludes ::
    SIValDefs (false, [ begindef; def; enddef ]) ::
    SIStretch grammar.postludes ::
  [])]

(* ------------------------------------------------------------------------- *)
(* Writing the program associated with a grammar to a file. *)

let write grammar filename () =
  let ml = open_out filename in
  let module P = Printer.Make (struct
    let f = ml
    let locate_stretches = Some filename
    let mode = Settings.PrintForOCamlyacc
  end) in
  P.program (program grammar);
  close_out ml

(* ------------------------------------------------------------------------- *)
(* Running ocamldep on the program. *)

type entry =
    string (* basename *) * string (* filename *)

type line =
    entry (* target *) * entry list (* dependencies *)

let depend postprocess grammar =

  (* Create an [.ml] file and an [.mli] file, then invoke ocamldep to
     compute dependencies for us. *)

  (* If an old [.ml] or [.mli] file exists, we are careful to preserve
     it. We temporarily move it out of the way and restore it when we
     are done. There is no reason why dependency analysis should
     destroy existing files. *)

  let ocamldep_command =
    Printf.sprintf "%s %s %s"
      Settings.ocamldep (Filename.quote mlname) (Filename.quote mliname)
  in

  let output : string =
    Option.project (
      IO.moving_away mlname (fun () ->
      IO.moving_away mliname (fun () ->
      IO.with_file mlname (write grammar mlname) (fun () ->
      IO.with_file mliname (Interface.write grammar) (fun () ->
      IO.invoke ocamldep_command
    )))))
  in

  (* Echo ocamldep's output. *)

  print_string output;

  (* If [--raw-depend] was specified on the command line, stop here.  This
     option is used by omake and by ocamlbuild, which performs their own
     postprocessing of [ocamldep]'s output. For normal [make] users, who use
     [--depend], some postprocessing is required, which is performed below. *)

  if postprocess then begin

    (* Make sense out of ocamldep's output. *)

    let lexbuf = Lexing.from_string output in
    let lines : line list =
      try
        Lexdep.main lexbuf
      with Lexdep.Error msg ->
        (* Echo the error message, followed with ocamldep's output. *)
        Error.error [] "%s" (msg ^ output)
    in

    (* Look for the line that concerns the [.cmo] target, and echo a
       modified version of this line, where the [.cmo] target is
       replaced with [.ml] and [.mli] targets, and where the dependency
       over the [.cmi] file is dropped.

       In doing so, we assume that the user's [Makefile] supports
       bytecode compilation, so that it makes sense to request [bar.cmo]
       to be built, as opposed to [bar.cmx]. This is not optimal, but
       will do. [camldep] exhibits the same behavior. *)

    List.iter (fun ((_, target_filename), dependencies) ->
      if Filename.check_suffix target_filename ".cmo" then
        let dependencies = List.filter (fun (basename, _) ->
          basename <> base
        ) dependencies in
        if List.length dependencies > 0 then begin
          Printf.printf "%s.ml %s.mli:" base base;
          List.iter (fun (_basename, filename) ->
            Printf.printf " %s" filename
          ) dependencies;
          Printf.printf "\n%!"
        end
    ) lines

  end;

  (* Stop. *)

  exit 0

(* ------------------------------------------------------------------------- *)
(* Augmenting a grammar with inferred type information. *)

(* The parameter [output] is supposed to contain the output of [ocamlc -i]. *)

let read_reply (output : string) grammar =

  (* See comment in module [Error]. *)
  Error.enable();

  let env : (string * int * int) list =
    Lexmli.main (Lexing.from_string output)
  in

  let env : (string * ocamltype) list =
    List.map (fun (id, openingofs, closingofs) ->
      decode id, Inferred (String.sub output openingofs (closingofs - openingofs))
    ) env
  in

  (* Augment the grammar with new %type declarations. *)

  let types =
    StringMap.fold (fun symbol _ types ->
      let ocamltype =
        try
          List.assoc (Misc.normalize symbol) env
        with Not_found ->
          (* No type information was inferred for this symbol.
             Perhaps the mock [.ml] file or the inferred [.mli] file
             are out of date. Fail gracefully. *)
          Error.error [] "found no inferred type for %s." symbol
      in
      if StringMap.mem symbol grammar.types then
        (* If there was a declared type, keep it. *)
        types
      else
        (* Otherwise, insert the inferred type. *)
        StringMap.add symbol ocamltype types
    ) grammar.rules grammar.types
  in

  { grammar with types = types }


(* ------------------------------------------------------------------------- *)
(* Inferring types for a grammar's nonterminals. *)

let infer grammar =

  (* Invoke ocamlc to do type inference for us. *)

  let ocamlc_command =
    Printf.sprintf "%s -c -i %s" Settings.ocamlc (Filename.quote mlname)
  in

  let output =
    write grammar mlname ();
    match IO.invoke ocamlc_command with
    | Some result ->
        Sys.remove mlname;
        result
    | None ->
        (* 2015/10/05: intentionally do not remove the [.ml] file if [ocamlc]
           fails. (Or if an exception is thrown.) *)
        exit 1
  in

  (* Make sense out of ocamlc's output. *)

  read_reply output grammar

(* ------------------------------------------------------------------------- *)

let write_query filename grammar =
  write grammar filename ();
  exit 0

(* ------------------------------------------------------------------------- *)

let read_reply filename grammar =
  read_reply (IO.read_whole_file filename) grammar
