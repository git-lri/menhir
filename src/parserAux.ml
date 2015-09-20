open Positions
open Syntax

let current_token_precedence =
  let c = ref 0 in
  fun pos1 pos2 ->
    incr c;
    PrecedenceLevel (Error.get_filemark (), !c, pos1, pos2)

let current_reduce_precedence =
  let c = ref 0 in
  fun () ->
    incr c;
    PrecedenceLevel (Error.get_filemark (), !c, Lexing.dummy_pos, Lexing.dummy_pos)

module IdSet = Set.Make (struct
  type t = identifier located
  let compare id1 id2 =
    compare (value id1) (value id2)
end)

let defined_identifiers (_, ido, _) accu =
  Option.fold IdSet.add ido accu

let defined_identifiers producers =
  List.fold_right defined_identifiers producers IdSet.empty

let check_production_group right_hand_sides =
  begin
    match right_hand_sides with
    | [] ->
	assert false
    | (producers, _, _, _) :: right_hand_sides ->
	let ids = defined_identifiers producers in
	List.iter (fun (producers, _, _, _) ->
	  let ids' = defined_identifiers producers in
	  try
	    let id =
	      IdSet.choose (IdSet.union
				  (IdSet.diff ids ids')
				  (IdSet.diff ids' ids))
	    in
	    Error.error [Positions.position id]
	      "Two productions that share a semantic action must define\n\
	       exactly the same identifiers."
	  with Not_found ->
	    ()
	  ) right_hand_sides
  end;
  right_hand_sides

(* [normalize_producer i p] assigns a name of the form [_i]
   to the unnamed producer [p]. *)
let normalize_producer i (pos, opt_identifier, parameter) =
  let id =
    match opt_identifier with
      | Some id -> id
      | None -> Positions.with_pos pos ("_" ^ string_of_int (i + 1))
  in
  (id, parameter)

let normalize_right_hand_side (producers, a, b, c) =
  (List.mapi normalize_producer producers, a, b, c)

let normalize_production_group right_hand_sides =
  right_hand_sides
  |> check_production_group
  |> List.map normalize_right_hand_side

let override pos o1 o2 =
  match o1, o2 with
  | Some _, Some _ ->
      Error.signal [ pos ] "This production carries two %prec declarations.";
      o2
  | None, Some _ ->
      o2
  | _, None ->
      o1

(* Support for on-the-fly expansion of anonymous rules. Whenever such
   a rule is encountered, we create a fresh non-terminal symbol, add
   a definition of this symbol to a global variable, and return a
   reference to this symbol. Quick and dirty. So, in the end, clean. *)

let fresh : unit -> string =
  let next = ref 0 in
  fun () ->
    Printf.sprintf "__anonymous_%d" (Misc.postincrement next)

let rules =
  ref []

let anonymous pos branches =
  (* Generate a fresh non-terminal symbol. *)
  let symbol = fresh() in
  (* Construct its definition. Note that it is implicitly marked %inline. *)
  let rule = {
    pr_public_flag = false; 
    pr_inline_flag = true;
    pr_nt          = symbol;
    pr_positions   = [ pos ]; (* this list is not allowed to be empty *)
    pr_parameters  = [];
    pr_branches    = branches
  } in
  (* Record this definition. *)
  rules := rule :: !rules;
  (* Return the symbol that stands for it. *)
  symbol

let rules () =
  let result = !rules in
  (* Reset the global state, in case we need to read several .mly files. *)
  rules := [];
  result

(* Only unnamed producers can be referred using positional identifiers.
   Besides, such positions must be taken in the interval [1
   .. List.length producers]. The output array [p] is such that
   [p.(idx) = Some x] if [idx] must be referred using [x], not
   [$(idx + 1)]. *)
let producer_names producers =
  let is_index identifier =
    Str.(string_match (regexp "_[0-9]+") identifier 0)
  in
  List.(
    producers
    |> map (fun ({ value = id }, _) -> if is_index id then None else Some id)
    |> Array.of_list
  )
