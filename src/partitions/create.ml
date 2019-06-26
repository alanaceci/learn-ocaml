open Learnocaml_data
open Learnocaml_data.Partition

open Learnocaml_report

open Lwt.Infix

open Utils

module IntMap = Map.Make(struct type t = int let compare = compare end)

let impl_of_string s =
  try Some (Parse.implementation (Lexing.from_string s))
  with
  | Lexer.Error _ | Syntaxerr.Error _ -> None

let take_until_last p =
  let rec aux = function
  | [] -> None
  | x::xs ->
     match aux xs with
     | None ->
        if p x
        then Some [x]
        else None
     | Some xs -> Some (x::xs)
  in aux

let to_typed_tree (lst : Parsetree.structure) =
  try
    Compmisc.init_path true;
    let init_env = Compmisc.initial_env () in
    let s,_,_ = Typemod.type_structure init_env lst Location.none
    in Some s
  with Typetexp.Error _ -> None

let has_name f x =
  let open Typedtree in
  match x.vb_pat.pat_desc with
  | Tpat_var (_,v) -> Asttypes.(v.txt) = f
  | _ -> false

let get_type_of_f_in_last f tree =
  let open Typedtree in
  let aux acc x =
    match x.str_desc with
    | Tstr_value (_,lst) ->
       begin
         match List.find_opt (has_name f) lst with
         | None -> acc
         | Some x -> Some x.vb_expr.exp_type
       end
    | _ -> acc
  in
  List.fold_left aux None tree.str_items

let find_func f : Parsetree.structure_item list -> Parsetree.structure option =
  let open Parsetree in
  let pred c =
    match c.pstr_desc with
    | Pstr_value (_,(x::_)) ->
       begin
         match x.pvb_pat.ppat_desc with
         | Ppat_var v -> Asttypes.(v.txt) = f
         | _ -> false
       end
    | _ -> false
  in
  take_until_last pred

(* Renvoie la liste des différents Answer.t associés à exo_name et fun_name *)
let get_all_saves exo_name prelude fun_name =
  Learnocaml_store.Student.Index.get () >>=
    Lwt_list.fold_left_s (* filter_map_rev *)
      (fun acc t ->
        let t = t.Student.token in
        Learnocaml_store.Save.get t >|= fun save ->
          maybe acc (fun x -> x :: acc) @@
          bindOption
            (fun x ->
              bindOption
                (fun x ->
                  fmapOption
                    (fun r -> t,x,r)
                    (bindOption (find_func fun_name) (impl_of_string (prelude ^ "\n" ^ Answer.(x.solution))))
                )
                (SMap.find_opt exo_name Save.(x.all_exercise_states))
            ) save
      ) []

let rec last = function
  | [] -> failwith "last"
  | [x] -> x
  | _::xs -> last xs

let find_sol_type prelude exo fun_name =
  let str = prelude ^ "\n"^Learnocaml_exercise.(decipher File.solution exo)  in
  match bindOption (find_func fun_name) (impl_of_string str) with
  | None -> failwith str
  | Some sol ->
     if sol = [] then print_endline "problem";
     let t = bindOption (get_type_of_f_in_last fun_name) @@
               to_typed_tree sol in
     match t with
     | None -> failwith "todo: gettype"
     | Some x -> x

let rec get_last_of_seq = function
  | Lambda.Lsequence (_,u) -> get_last_of_seq u
  | x -> x

let to_lambda (lst : Typedtree.structure) =
  get_last_of_seq @@
    Simplif.simplify_lambda "" @@
      Lambda_utils.inline_all @@
        Translmod.transl_toplevel_definition lst

(* Renvoie un couple où:
   - Le premier membre contient les réponses sans notes
   - Le second contient les report des réponses notées
*)
let partition_WasGraded =
  let aux (nonlst,acc) ((a,x,b) as e) =
    match Answer.(x.report) with
    | None -> e::nonlst,acc
    | Some g -> nonlst,(a,g,b)::acc
  in
  List.fold_left aux ([], [])

let eq_type t1 t2 =
  let init_env = Compmisc.initial_env () in
  try Ctype.unify init_env t1 t2; true with
  | Ctype.Unify _ -> false

let partition_FunExist sol_type fun_name =
  let pred (_,_,x) =
    match bindOption (get_type_of_f_in_last fun_name) (to_typed_tree x) with
    | None -> false
    | Some x -> eq_type x sol_type
  in List.partition pred

let partition_by_grade funname =
  let rec get_relative_section = function
    | [] -> []
    | (Message _)::xs -> get_relative_section xs
    | (Section (t,res))::xs ->
       match t with
       | Text func::Code  fn::_ ->
          if func = "Function:" && fn = funname
          then res
          else get_relative_section xs
       | _ -> get_relative_section xs
  in
  let rec get_grade xs =
    let aux acc =
      function
      | Section (_,s) -> get_grade s
      | Message (_,s) ->
         match s with
         | Success i -> acc + i
         | _ -> acc
    in
    List.fold_left aux 0 xs
  in
  let aux acc ((_,x,_) as e) =
    let sec = get_relative_section x in
    let g = get_grade sec in
    let lst =
      match IntMap.find_opt g acc with
      | None -> [e]
      | Some xs -> e::xs
    in IntMap.add g lst acc
  in
  List.fold_left aux IntMap.empty

let hm_part prof m =
  let hashtbl = Hashtbl.create 100 in
  List.iter
    (fun (t,_,(_,x)) ->
      let hash,lst = Lambda_utils.hash_lambda prof x in
      Hashtbl.add hashtbl t (hash::lst)
    ) m;
  Clustering.cluster hashtbl

exception Found of Parsetree.structure_item
let assoc_3 t lst =
  try
    List.iter (fun (t',_,(x,_)) -> if t = t' then raise (Found x) else ()) lst;
    failwith "assoc_3"
  with
  | Found x -> x

let string_of_bindings x =
  Pprintast.string_of_structure [x]

let refine_with_hm prof =
  IntMap.map @@
    fun x ->
    List.map
      (fold_tree
         (fun f a b -> Node (f,a,b))
         (fun xs -> Leaf (List.map (fun u -> u,string_of_bindings (assoc_3 u x)) xs)))
    (hm_part prof x)

let list_of_IntMap m =
  IntMap.fold (fun k a acc -> (k,a)::acc) m []

let map_to_lambda bad_type =
  List.fold_left
    (fun (bad,good) (a,b,c) ->
      try bad,(a,b,(last c,to_lambda (match to_typed_tree c with None -> failwith "here" | Some s -> s)))::good
      with Typetexp.Error _ -> a::bad,good)
    (bad_type,[])

let partition exo_name fun_name prof =
  Learnocaml_store.Exercise.get exo_name
  >>= fun exo ->
  let prelude = Learnocaml_exercise.(access File.prelude exo) in
  get_all_saves exo_name prelude fun_name
  >|= fun saves ->
  let sol_type = find_sol_type prelude exo fun_name in
  let not_graded,lst = partition_WasGraded saves in
  let not_graded = List.map (fun (x,_,_) -> x) not_graded in
  let funexist,bad_type = partition_FunExist sol_type fun_name lst in
  let bad_type = List.map (fun (x,_,_) -> x) bad_type in
  let bad_type,funexist = map_to_lambda bad_type funexist in
  let map = list_of_IntMap @@ refine_with_hm prof @@ partition_by_grade fun_name funexist in
  {not_graded; bad_type; patition_by_grade=map}
