open Keyword

type t = {

  (* The code for this semantic action. *)
  expr: IL.expr;

  (* The files where this semantic action originates. Via inlining,
     several semantic actions can be combined into one, so there can
     be several files. *)
  filenames: string list;

  (* A list of keywords that appear in this semantic action, with their
     positions. This list is maintained only up to the well-formedness check in
     [PartialGrammar.check_keywords]. Thereafter, it is no longer used. So, the
     keyword-renaming functions do not bother to update it. *)
  pkeywords : keyword Positions.located list;

  (* The set of keywords that appear in this semantic action. They can be thought
     of as free variables that refer to positions. They must be renamed during
     inlining. *)
  keywords  : KeywordSet.t;

}

(* Creation. *)

let pkeywords_to_keywords pkeywords =
  KeywordSet.of_list (List.map Positions.value pkeywords)

let from_stretch s = 
  let pkeywords = s.Stretch.stretch_keywords in
  { 
    expr      = IL.ETextual s;
    filenames = [ s.Stretch.stretch_filename ];
    pkeywords = pkeywords;
    keywords  = pkeywords_to_keywords pkeywords;
  }

(* Composition, used during inlining. *)

let compose x a1 a2 = 
  (* 2015/07/20: there used to be a call to [parenthesize_stretch] here,
     which would insert parentheses around every stretch in [a1]. This is
     not necessary, as far as I can see, since every stretch that represents
     a semantic action is already parenthesized by the lexer. *)
  {
    expr      = IL.ELet ([ IL.PVar x, a1.expr ], a2.expr);
    keywords  = KeywordSet.union a1.keywords a2.keywords;
    filenames = a1.filenames @ a2.filenames;
    pkeywords = [] (* don't bother; already checked *)
  }

(* Substitutions, represented as association lists.
   In principle, no name appears twice in the domain. *)

type subst =
  (string * string) list

let apply (phi : subst) (s : string) : string =
  try 
    List.assoc s phi
  with Not_found ->
    s 

let apply_subject (phi : subst) (subject : subject) : subject =
  match subject with
  | Left ->
      Left
  | RightNamed s ->
      RightNamed (apply phi s)

let extend x y (phi : subst ref) =
  assert (not (List.mem_assoc x !phi));
  if x <> y then
    phi := (x, y) :: !phi

(* Renaming of keywords, used during inlining. *)

type sw =
  Keyword.subject * Keyword.where

type keyword_renaming =
  string * sw * sw

let rename_sw_outer
    ((psym, first_prod, last_prod) : keyword_renaming)
    (subject, where) : sw option =
  match subject with
  | RightNamed s ->
      if s = psym then
        match where with
        | WhereStart -> Some first_prod
        | WhereEnd   -> Some last_prod
      else
        None
  | Left ->
      None

let rename_sw_inner
    ((_, first_prod, last_prod) : keyword_renaming)
    (subject, where) : sw option =
  match subject, where with
  | Left, WhereStart -> Some first_prod
  | Left, WhereEnd   -> Some last_prod
  | RightNamed _, _ ->  None

(* [rename_keyword f phi keyword] applies the function [f] to possibly change
   the keyword [keyword]. If [f] decides to change this keyword (by returning
   [Some _]) then this decision is obeyed. Otherwise, the keyword is renamed
   by the substitution [phi]. In either case, [phi] is extended with a
   renaming decision. *)

let rename_keyword (f : sw -> sw option) (phi : subst ref) keyword : keyword =
  match keyword with
  | SyntaxError ->
      SyntaxError
  | Position (subject, where, flavor) ->
      let subject', where' = 
        match f (subject, where) with
        | Some (subject', where') ->
            subject', where'
        | None ->
            apply_subject !phi subject, where
      in
      extend
        (Keyword.posvar subject where flavor)
        (Keyword.posvar subject' where' flavor)
        phi;
      Position (subject', where', flavor)

(* [rename f phi a] applies to the semantic action [a] the renaming [phi]
   as well as the renaming decisions made by the function [f]. [f] is
   applied to (not-yet-renamed) keywords and may decide to change them
   (by returning [Some _]). *)

let rename f phi a = 

  (* Rename all keywords, growing [phi] as we go. *)
  let keywords = a.keywords in
  let phi = ref phi in
  let keywords = KeywordSet.map (rename_keyword f phi) keywords in
  let phi = !phi in

  (* Construct a new semantic action, where [phi] is translated into
     a series of [let] bindings. *)
  let phi = List.map (fun (x, y) -> IL.PVar x, IL.EVar y) phi in
  let expr = IL.ELet (phi, a.expr) in

  { 
    expr      = expr;
    filenames = a.filenames;
    pkeywords = []; (* don't bother *)
    keywords  = keywords;
  }

let rename_outer renaming =
  rename (rename_sw_outer renaming)

let rename_inner renaming =
  rename (rename_sw_inner renaming)

let to_il_expr action = 
  action.expr

let filenames action = 
  action.filenames

let keywords action = 
  action.keywords

let pkeywords action = 
  action.pkeywords

let print f action = 
  let module P = Printer.Make (struct let f = f 
				      let locate_stretches = None 
			       end) 
  in
    P.expr action.expr

let has_syntaxerror action =
  KeywordSet.mem SyntaxError (keywords action)

let has_leftstart action =
  KeywordSet.exists (function
    | Position (Left, WhereStart, _) ->
	true
    | _ ->
	false
  ) (keywords action)

let has_leftend action =
  KeywordSet.exists (function
    | Position (Left, WhereEnd, _) ->
	true
    | _ ->
	false
  ) (keywords action)

