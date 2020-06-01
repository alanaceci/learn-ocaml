exception UnimplementedConstruct of string

(* Helpers *)
let map_opt f = function
  | None -> None
  | Some x -> Some (f x)
let map_snd f (x, y) = (x, f y)
let loc x = {Asttypes.txt = x; loc = Location.none}

module PtoS = struct

  (* Helpers *)
  let map_opt2 f x1 x2 =
    match x1, x2 with
    | None, None -> None
    | Some y1, Some y2 -> Some (f y1 y2)
    | _ -> assert false
  let map_snd2 f (x1, y1) (_, y2) = (x1, f y1 y2)

  (* The typed tree reorders fields for applications of labelled
     functions and record expressions. This is a helper for
     putting fields back in the order they were given in the
     parse tree.

     split p l returns a pair of:
     - the first element in l that satisfies the predicate p
     - the list l with that element removed.
     Precondition: at least one element of l satisfies p.
   *)
  let rec split p l =
    match l with
    | [] -> assert false
    | x :: xs ->
        if p x then (x, xs)
        else
          let (x', xs) = split p xs in
          (x', x :: xs)

  (* The typing environment *)
  let env = ref (Env.empty) (* needs to be initialized at runtime *)
  let init_env () = env := !Toploop.toplevel_env
  let lookup_lid lid = fst @@ Env.lookup_value lid !env

  open Parsetree
  open Typed_ast
  open Typedtree

  let rec structure str =
    let (tstr, _, _) = Typemod.type_structure !env str Location.none in
    str_aux str tstr

  and expression expr =
    let texpr = Typecore.type_exp !env expr in
    expr_aux expr texpr

  and value_binding vb tvb =
    let {pvb_pat; pvb_expr; _} = vb in
    let {vb_pat; vb_expr; _} = tvb in
    let svb_pat = pattern pvb_pat vb_pat in
    let svb_expr = expr_aux pvb_expr vb_expr in
    {svb_pat; svb_expr}

  and case case tcase =
    let {pc_lhs; pc_guard; pc_rhs} = case in
    let {c_lhs; c_guard; c_rhs} = tcase in
    let sc_lhs = pattern pc_lhs c_lhs in
    let sc_guard = map_opt2 expr_aux pc_guard c_guard in
    let sc_rhs = expr_aux pc_rhs c_rhs in
    {sc_lhs; sc_guard; sc_rhs}

  and expr_aux expr texpr =
    let {pexp_desc = desc; pexp_loc = loc; pexp_attributes = attrs; _} = expr
    in
    let {exp_desc = tdesc; exp_type = typ; exp_env; _} = texpr in
    let sexp_desc = match desc, tdesc with
      | Pexp_ident _, Texp_ident (path, lid, _) ->
          Sexp_ident (path, lid)
      | Pexp_constant c, Texp_constant _ ->
          Sexp_constant c
      | Pexp_let (_, vbs, expr), Texp_let (rf, tvbs, texpr) ->
          let vbs = List.map2 value_binding vbs tvbs in
          let expr = expr_aux expr texpr in
          Sexp_let (rf, vbs, expr)

      | Pexp_function cases, Texp_function {cases = tcases; _} ->
          let cases = List.map2 case cases tcases in
          Sexp_function cases
      | Pexp_fun (Asttypes.Optional _, Some _, _, _), Texp_function _ ->
          treat_fun_optional_argument expr.pexp_desc texpr.exp_desc
      | Pexp_fun (label, None, pat, expr),
        Texp_function {cases = [case]; _} ->
          (* fun x -> expr is translated to function x -> expr *)
          let {c_lhs = tpat; c_rhs = texpr; _} = case in
          let pat = pattern pat tpat in
          let expr = expr_aux expr texpr in
          Sexp_fun (label, None, pat, expr)

      | Pexp_apply (f, args), Texp_apply (tf, targs) ->
          treat_apply f args tf targs

      | Pexp_match (expr, cases), Texp_match (texpr, tcases, exns, _) ->
          if exns <> [] then raise (UnimplementedConstruct "match")
          else
            let expr = expr_aux expr texpr in
            let cases = List.map2 case cases tcases in
            Sexp_match (expr, cases)
      | Pexp_try (expr, cases), Texp_try (texpr, tcases) ->
          let expr = expr_aux expr texpr in
          let cases = List.map2 case cases tcases in
          Sexp_try (expr, cases)

      | Pexp_tuple exprs, Texp_tuple texprs ->
          let exprs = List.map2 expr_aux exprs texprs in
          Sexp_tuple exprs

      | Pexp_construct (lid, None), Texp_construct (_, _, []) ->
          Sexp_construct (lid, None)
      | Pexp_construct (lid, Some expr), Texp_construct (_, _, texprs) ->
          let texpr = match texprs with
            | [texpr] -> texpr
            | _ ->
                let types = List.map (fun t -> t.exp_type) texprs in
                let exp_desc = Texp_tuple texprs in
                let exp_type =
                  {Types.desc = Types.Ttuple types; level = -1; id = -1}
                in
                {exp_desc;
                 exp_loc = Location.none;
                 exp_extra = [];
                 exp_type;
                 exp_env;
                 exp_attributes = []}
          in
          let expr = expr_aux expr texpr in
          Sexp_construct (lid, Some expr)

      | Pexp_record (fields, expo),
        Texp_record {fields = tfields; extended_expression = texpo; _} ->
          treat_record_expr fields expo tfields texpo

      | Pexp_field (expr, lid), Texp_field (texpr, _, _) ->
          let expr = expr_aux expr texpr in
          Sexp_field (expr, lid)
      | Pexp_setfield (e1, lid, e2), Texp_setfield (te1, _, _, te2) ->
          let e1 = expr_aux e1 te1 in
          let e2 = expr_aux e2 te2 in
          Sexp_setfield (e1, lid, e2)

      | Pexp_ifthenelse (e1, e2, e3), Texp_ifthenelse(te1, te2, te3) ->
          Sexp_ifthenelse (expr_aux e1 te1,
                           expr_aux e2 te2,
                           map_opt2 expr_aux e3 te3)
      | Pexp_sequence (e1, e2), Texp_sequence (te1, te2) ->
          let e1 = expr_aux e1 te1 in
          let e2 = expr_aux e2 te2 in
          Sexp_sequence (e1, e2)

      | Pexp_constraint (expr, typ), _ ->
          begin
            match texpr.exp_extra with
            | (Texp_constraint _, _, _) :: exp_extra ->
                let texpr = {texpr with exp_extra} in
                let expr = expr_aux expr texpr in
                Sexp_constraint (expr, typ)
            | _ -> assert false
          end

      | Pexp_assert expr, Texp_assert texpr ->
          let expr = expr_aux expr texpr in
          Sexp_assert expr

      | Pexp_open (ovf, lid, expr), _ ->
          begin
            match texpr.exp_extra with
            | (Texp_open _, _, _) :: exp_extra ->
                let texpr = {texpr with exp_extra} in
                let expr = expr_aux expr texpr in
                Sexp_open (ovf, lid, expr)
            | _ -> assert false
          end

      | _ ->
          raise (UnimplementedConstruct "expression")
    in
    {sexp_desc;
     sexp_env = exp_env;
     sexp_type = typ;
     sexp_loc = loc;
     sexp_attrs = attrs;}

  and pattern pat tpat =
    match pat.ppat_desc, tpat.pat_desc with
    | Ppat_any, Tpat_any -> Spat_any
    | Ppat_var _, Tpat_var (id, str) -> Spat_var (id, str)
    (* Sometimes pattern variables x are transformed to (_ as x) *)
    | Ppat_var _, Tpat_alias ({pat_desc = Tpat_any; pat_loc; _}, id, str)
      when pat_loc = pat.ppat_loc ->
        Spat_var (id, str)
    | Ppat_alias (pat, _), Tpat_alias (tpat, id, str) ->
        let pat = pattern pat tpat in
        Spat_alias (pat, id, str)
    | Ppat_constant c, Tpat_constant _ -> Spat_constant c

    | Ppat_tuple pats, Tpat_tuple tpats ->
        let pats = List.map2 pattern pats tpats in
        Spat_tuple pats

    | Ppat_construct (lid, None), Tpat_construct (_, _, []) ->
        Spat_construct (lid, None)
    | Ppat_construct (lid, Some pat), Tpat_construct (_, _, tpats) ->
        let tpat = match tpats with
          | [tpat] -> tpat
          | _ ->
              let types = List.map (fun p -> p.pat_type) tpats in
              let pat_desc = Tpat_tuple tpats in
              let pat_type =
                {Types.desc = Types.Ttuple types; level = -1; id = -1}
              in
              {pat_desc;
               pat_loc = Location.none;
               pat_extra = [];
               pat_type;
               pat_env = Env.empty;
               pat_attributes = []}
        in
        let pat = pattern pat tpat in
        Spat_construct (lid, Some pat)

    | Ppat_record (fields, cf), Tpat_record (tfields, _) ->
        let tfields =
          List.map
            (fun (lid, _, tpat) -> (lid, tpat))
            tfields
        in
        let fields = List.map2 (map_snd2 pattern) fields tfields in
        Spat_record (fields, cf)

    | Ppat_or (p1, p2), Tpat_or (tp1, tp2, _) ->
        let p1 = pattern p1 tp1 in
        let p2 = pattern p2 tp2 in
        Spat_or (p1, p2)

    | Ppat_constraint (pat, typ), _ ->
        begin
          match tpat.pat_extra with
          | (Tpat_constraint _, _, _) :: _ ->
              let pat = pattern pat tpat in
              Spat_constraint (pat, typ)
          | _ -> assert false
        end

    | _ -> raise (UnimplementedConstruct "pattern")

  and str_aux str tstr =
    let sstr_type = tstr.str_type in
    let sstr_env = tstr.str_final_env in
    let sstr_items = List.map2 structure_item str tstr.str_items in
    {sstr_items; sstr_type; sstr_env}

  and structure_item item titem =
    match item.pstr_desc, titem.str_desc with
    | Pstr_eval (expr, _), Tstr_eval (texpr, _) ->
        let expr = expr_aux expr texpr in
        Sstr_eval expr
    | Pstr_value (rf, vbs), Tstr_value (_, tvbs) ->
        let vbs = List.map2 value_binding vbs tvbs in
        Sstr_value (rf, vbs)
    | Pstr_primitive vd, Tstr_primitive _ ->
        Sstr_primitive vd
    | Pstr_type (rf, tds), Tstr_type _ ->
        Sstr_type (rf, tds)
    | Pstr_exception ec, Tstr_exception _ ->
        Sstr_exception ec
    | Pstr_module mb, Tstr_module tmb ->
        let mb = module_binding mb tmb in
        Sstr_module mb
    | Pstr_modtype mtd, Tstr_modtype _ ->
        Sstr_modtype mtd
    | Pstr_open od, Tstr_open _ ->
        Sstr_open od
    | _ -> raise (UnimplementedConstruct "structure_item")

  and module_binding mb tmb =
    let {pmb_name; pmb_expr; _} = mb in
    let {mb_expr; _} = tmb in
    let smb_expr = module_expr pmb_expr mb_expr in
    {smb_name = pmb_name; smb_expr}

  and module_expr me tme =
    match me.pmod_desc, tme.mod_desc with
    (* Implicit module type constraints added during
       typechecking: drop them *)
    | _, Tmod_constraint (tme, _, Tmodtype_implicit, _) ->
        module_expr me tme
    | Pmod_ident lid, Tmod_ident _ -> Smod_ident lid
    | Pmod_structure str, Tmod_structure tstr ->
        let str = str_aux str tstr in
        Smod_structure str
    | Pmod_functor (name, mto, me), Tmod_functor (_, _, _, tme) ->
        let me = module_expr me tme in
        Smod_functor (name, mto, me)
    | Pmod_apply (me1, me2), Tmod_apply (tme1, tme2, _) ->
        let me1 = module_expr me1 tme1 in
        let me2 = module_expr me2 tme2 in
        Smod_apply (me1, me2)
    | Pmod_constraint (me, mt), Tmod_constraint (tme, _, _, _) ->
        let me = module_expr me tme in
        Smod_constraint (me, mt)
    | _ -> raise (UnimplementedConstruct "module_expr")

  and treat_fun_optional_argument exp texp =
    match exp, texp with
    | Pexp_fun ((Asttypes.Optional _) as label, Some exp1, pat, expr),
      Texp_function {cases = [{c_rhs = case; _}]; _} ->
        (* fun ?(x = exp1) -> exp2 is translated to (roughly):
           function opt ->
             let x = match opt with
             | None -> exp1
             | Some sth -> sth
             in exp2
         *)
        let tpat, tmatch, texpr = match case.exp_desc with
          | Texp_let (_, [{vb_pat = tpat; vb_expr = tmatch; _}], texpr) ->
              tpat, tmatch, texpr
          | _ -> assert false
        in
        let tcase1, tcase2 = match tmatch.exp_desc with
          | Texp_match (_, [tcase1; tcase2], _, _) -> tcase1, tcase2
          | _ -> assert false
        in
        (* The order of cases isn't consistent, so check both.
           The None case is the one with no constructor arguments. *)
        let texp1 =
          match tcase1, tcase2 with
          | {c_lhs = {pat_desc = Tpat_construct (_, _, []); _}; c_rhs; _}, _ ->
              c_rhs
          | _, {c_lhs = {pat_desc = Tpat_construct (_, _, []); _}; c_rhs; _} ->
              c_rhs
          | _ -> assert false
        in
        let expo = Some (expr_aux exp1 texp1) in
        let pat = pattern pat tpat in
        let expr = expr_aux expr texpr in
        Sexp_fun (label, expo, pat, expr)
    | _ -> assert false

  (* The typed tree fills in labelled arguments and
     reorders arguments for applications of functions with
     labelled arguments. We need to drop all the arguments
     that weren't actually given in the AST and put the
     rest back in the correct order. *)
  and treat_apply f args tf targs =
        let is_labelled arg = match arg with
          | (Asttypes.Nolabel, _) -> false
          | _ -> true
        in
        let plargs, pargs = List.partition is_labelled args in
        let tlargs, targs = List.partition is_labelled targs in
        let deopt l =
          List.fold_right
            (fun x acc -> match x with
               (* Non-labelled argument that was abstracted over *)
               | (_, None) -> acc

               (* Optional argument that was filled in *)
               | (Asttypes.Optional _,
                  Some {exp_desc = Texp_construct (
                      {Asttypes.txt = Longident.Lident "None"; _},
                      _,
                      _); _}) -> acc

               (* Optional argument that was provided and wrapped in
                  an option *)
               | ((Asttypes.Optional _ as label),
                  Some {exp_desc = Texp_construct (
                      {Asttypes.txt = Longident.Lident "Some"; _},
                      _,
                      [x]); _}) -> (label, x) :: acc

               | (label, Some x) -> (label, x) :: acc)
            l
            []
        in
        let targs = deopt targs in
        let tlargs = deopt tlargs in
        let label l = match l with
          | Asttypes.Optional x -> x
          | Asttypes.Labelled x -> x
          | _ -> assert false
        in
        let same_label pl =
          let l = label pl in
          fun (tl, _) -> label tl = l
        in
        let rec match_args plargs tlargs =
          match plargs, tlargs with
          | [], _ -> ([], [])
          | (pl, plarg) :: plargs', tlargs ->
              let tlarg, tlargs' = split (same_label pl) tlargs in
              let plargs', tlargs' = match_args plargs' tlargs' in
              ((pl, plarg) :: plargs', tlarg :: tlargs')
        in
        let plargs, tlargs = match_args plargs tlargs in
        (* Preserve the order of arguments as given in the parse tree,
           because the typed tree reorders them... *)
        let rec merge_args orig pargs targs plargs tlargs =
          match orig with
          | [] -> ([], [])
          | (label, _) :: args ->
              if label = Asttypes.Nolabel then
                match pargs, targs with
                | parg :: pargs, targ :: targs ->
                    let pargs', targs' =
                      merge_args args pargs targs plargs tlargs
                    in
                    (parg :: pargs', targ :: targs')
                | _ -> assert false
              else
                match plargs, tlargs with
                | plarg :: plargs, tlarg :: tlargs ->
                    let pargs', targs' =
                      merge_args args pargs targs plargs tlargs
                    in
                    (plarg :: pargs', tlarg :: targs')
                | _ -> assert false
        in
        let pargs, targs = merge_args args pargs targs plargs tlargs in
        let f = expr_aux f tf in
        let args = List.map2 (map_snd2 expr_aux) pargs targs in
        Sexp_apply (f, args)

  (* The typed tree reorders and fills in record fields:
     we need to drop the filled-in ones and put the rest back in the
     order they were in in the parse tree.
   *)
  and treat_record_expr fields expo tfields texpo =
    let tfields =
      Array.fold_right
        (fun field acc ->
           match field with
           | _, Kept _ -> acc
           | _, Overridden (lid, expr) -> (lid, expr) :: acc)
        tfields []
    in
    let same_lid lid (tlid, _) = lid = tlid in
    let rec match_fields pfields tfields =
      match pfields, tfields with
      | [], [] -> ([], [])
      | (lid, pexp) :: pfields, tfields ->
          let (tfield, tfields) = split (same_lid lid) tfields in
          let pfields', tfields' = match_fields pfields tfields in
          ((lid, pexp) :: pfields', tfield :: tfields')
      | _ -> assert false
    in
    let fields, tfields = match_fields fields tfields in
    let fields = List.map2 (map_snd2 expr_aux) fields tfields in
    (* Corner case: if expo is not None, but all record fields are
       also explicitly listed, texpo will be None.
       In this case, let's just pretend that expo was None as well,
       since it was erased from the typed tree.
    *)
    let expo = if texpo = None then None else expo in
    let expo = map_opt2 expr_aux expo texpo in
    Sexp_record (fields, expo)

  (* Typed_ast fragments of patterns without pattern variables *)
  let rec pat p =
    match p.ppat_desc with
    | Ppat_var _
    | Ppat_alias _ -> raise (UnimplementedConstruct "pat")
    | Ppat_any -> Spat_any
    | Ppat_constant c -> Spat_constant c
    | Ppat_tuple pats -> Spat_tuple (List.map pat pats)
    | Ppat_construct (lid, pato) ->
        Spat_construct (lid, map_opt pat pato)
    | Ppat_record (fields, cf) ->
        Spat_record (List.map (map_snd pat) fields, cf)
    | Ppat_or (p1, p2) -> Spat_or (pat p1, pat p2)
    | Ppat_constraint (p, typ) -> Spat_constraint (pat p, typ)
    | _ -> raise (UnimplementedConstruct "pat")

end

module StoP = struct
  module P = Parsetree
  module S = Typed_ast

  type mapper = {
    expression:     mapper -> S.expression -> P.expression;
    pattern:        mapper -> S.pattern -> P.pattern;
    module_expr:    mapper -> S.module_expr -> P.module_expr;
    structure:      mapper -> S.structure -> P.structure;
    structure_item: mapper -> S.structure_item -> P.structure_item;
    case:           mapper -> S.case -> P.case;
    value_binding:  mapper -> S.value_binding -> P.value_binding;
    module_binding: mapper -> S.module_binding -> P.module_binding;
  }

  open P
  open S

  let expression sub expr =
    let pexp_loc = Location.none in
    let pexp_attributes = [] in
    let pexp_desc =
      match expr.sexp_desc with
      | Sexp_ident (_, lid) -> Pexp_ident lid
      | Sexp_constant c -> Pexp_constant c
      | Sexp_let (rf, vbs, expr) ->
          Pexp_let (rf,
                    List.map (sub.value_binding sub) vbs,
                    sub.expression sub expr)
      | Sexp_function cases ->
          Pexp_function (List.map (sub.case sub) cases)
      | Sexp_fun (label, expo, pat, exp) ->
          Pexp_fun (label,
                    map_opt (sub.expression sub) expo,
                    sub.pattern sub pat,
                    sub.expression sub exp)
      | Sexp_apply (f, args) ->
          Pexp_apply (sub.expression sub f,
                      List.map (map_snd @@ sub.expression sub) args)
      | Sexp_match (exp, cases) ->
          Pexp_match (sub.expression sub exp,
                      List.map (sub.case sub) cases)
      | Sexp_try (exp, cases) ->
          Pexp_try (sub.expression sub exp,
                    List.map (sub.case sub) cases)
      | Sexp_tuple exps ->
          Pexp_tuple (List.map (sub.expression sub) exps)
      | Sexp_construct (lid, expo) ->
          Pexp_construct (lid, map_opt (sub.expression sub) expo)
      | Sexp_record (fields, expo) ->
          Pexp_record (List.map (map_snd @@ sub.expression sub) fields,
                       map_opt (sub.expression sub) expo)
      | Sexp_field (exp, lid) ->
          Pexp_field (sub.expression sub exp, lid)
      | Sexp_setfield (exp1, lid, exp2) ->
          Pexp_setfield (sub.expression sub exp1,
                         lid,
                         sub.expression sub exp2)
      | Sexp_ifthenelse (e1, e2, e3) ->
          Pexp_ifthenelse (sub.expression sub e1,
                           sub.expression sub e2,
                           map_opt (sub.expression sub) e3)
      | Sexp_sequence (e1, e2) ->
          Pexp_sequence (sub.expression sub e1,
                         sub.expression sub e2)
      | Sexp_constraint (exp, typ) ->
          Pexp_constraint (sub.expression sub exp, typ)
      | Sexp_assert exp -> Pexp_assert (sub.expression sub exp)
      | Sexp_open (ovf, lid, exp) ->
          Pexp_open (ovf,
                     lid,
                     sub.expression sub exp)
    in
    {pexp_desc; pexp_loc; pexp_attributes}

  let value_binding sub {svb_pat; svb_expr} =
    let pvb_pat = sub.pattern sub svb_pat in
    let pvb_expr = sub.expression sub svb_expr in
    let pvb_attributes = [] in
    let pvb_loc = Location.none in
    {pvb_pat; pvb_expr; pvb_attributes; pvb_loc}

  let case sub {sc_lhs; sc_guard; sc_rhs} =
    let pc_lhs = sub.pattern sub sc_lhs in
    let pc_guard = map_opt (sub.expression sub) sc_guard in
    let pc_rhs = sub.expression sub sc_rhs in
    {pc_lhs; pc_guard; pc_rhs}

  let pattern sub pat =
    let ppat_loc = Location.none in
    let ppat_attributes = [] in
    let ppat_desc = match pat with
      | Spat_any -> Ppat_any
      | Spat_var (_, name) -> Ppat_var name
      | Spat_alias (pat, _, name) ->
          Ppat_alias (sub.pattern sub pat, name)
      | Spat_constant c -> Ppat_constant c
      | Spat_tuple pats ->
          Ppat_tuple (List.map (sub.pattern sub) pats)
      | Spat_construct (lid, pato) ->
          Ppat_construct (lid, map_opt (sub.pattern sub) pato)
      | Spat_record (fields, cf) ->
          Ppat_record (List.map (map_snd @@ sub.pattern sub) fields,
                       cf)
      | Spat_or (p1, p2) ->
          Ppat_or (sub.pattern sub p1,
                   sub.pattern sub p2)
      | Spat_constraint (pat, typ) ->
          Ppat_constraint (sub.pattern sub pat, typ)
    in
    {ppat_desc; ppat_loc; ppat_attributes}

  let module_expr sub me =
    let pmod_loc = Location.none in
    let pmod_attributes = [] in
    let pmod_desc =
      match me with
      | Smod_ident lid -> Pmod_ident lid
      | Smod_structure str -> Pmod_structure (sub.structure sub str)
      | Smod_functor (name, mto, me) ->
          Pmod_functor (name, mto, sub.module_expr sub me)
      | Smod_apply (me1, me2) ->
          Pmod_apply (sub.module_expr sub me1,
                      sub.module_expr sub me2)
      | Smod_constraint (me, mt) ->
          Pmod_constraint (sub.module_expr sub me, mt)
    in
    {pmod_desc; pmod_loc; pmod_attributes}

  let structure sub str =
    List.map (sub.structure_item sub) str.sstr_items

  let structure_item sub item =
    let pstr_loc = Location.none in
    let pstr_desc = match item with
      | Sstr_eval exp -> Pstr_eval (sub.expression sub exp, [])
      | Sstr_value (rf, vbs) ->
          Pstr_value (rf,
                      List.map (sub.value_binding sub) vbs)
      | Sstr_primitive vd -> Pstr_primitive vd
      | Sstr_type (rf, tds) -> Pstr_type (rf, tds)
      | Sstr_exception ec -> Pstr_exception ec
      | Sstr_module mb -> Pstr_module (sub.module_binding sub mb)
      | Sstr_modtype mtd -> Pstr_modtype mtd
      | Sstr_open od -> Pstr_open od
    in
    {pstr_desc; pstr_loc}

  let module_binding sub {smb_name; smb_expr} =
    {pmb_name = smb_name;
     pmb_expr = sub.module_expr sub smb_expr;
     pmb_attributes = [];
     pmb_loc = Location.none}

  let default_mapper = {
    expression;
    pattern;
    module_expr;
    structure;
    structure_item;
    case;
    value_binding;
    module_binding;
  }

  let rec lid_of_path ?(unique_name=true) = function
    | Path.Pident ident ->
        let get_name =
          if unique_name && not (Ident.persistent ident)
          then Ident.unique_name
          else Ident.name
        in
        Longident.Lident (get_name ident)
    | Path.Pdot (path, str, _) ->
        Longident.Ldot (lid_of_path ~unique_name: false path, str)
    | Path.Papply _ -> raise (UnimplementedConstruct "Papply")

  let unique_id_mapper =
    let expression sub expr = match expr.sexp_desc with
      | Sexp_ident (path, _) ->
          let lid = loc (lid_of_path path) in
          {pexp_desc = Pexp_ident lid;
           pexp_loc = Location.none;
           pexp_attributes = []}
      | _ -> default_mapper.expression sub expr
    in
    let pattern sub = function
      | Spat_var (ident, _) ->
          let name = loc (Ident.unique_name ident) in
          {ppat_desc = Ppat_var name;
           ppat_loc = Location.none;
           ppat_attributes = []}
      | Spat_alias (pat, ident, _) ->
          let pat = sub.pattern sub pat in
          let name = loc (Ident.unique_name ident) in
          {ppat_desc = Ppat_alias (pat, name);
           ppat_loc = Location.none;
           ppat_attributes = []}
      | pat -> default_mapper.pattern sub pat
    in
    {default_mapper with expression; pattern}

end

module Typed_ast_mapper = struct
  open Typed_ast

  type mapper = {
    expression:     mapper -> expression -> expression;
    pattern:        mapper -> pattern -> pattern;
    case:           mapper -> case -> case;
    value_binding:  mapper -> value_binding -> value_binding;
    module_expr:    mapper -> module_expr -> module_expr;
    structure:      mapper -> structure -> structure;
    structure_item: mapper -> structure_item -> structure_item;
    module_binding: mapper -> module_binding -> module_binding;
  }

  let expression sub expr =
    let sexp_type = expr.sexp_type in
    let sexp_env = expr.sexp_env in
    let sexp_loc = expr.sexp_loc in
    let sexp_attrs = expr.sexp_attrs in
    let sexp_desc = match expr.sexp_desc with
    | Sexp_ident _
    | Sexp_constant _ as expr -> expr
    | Sexp_let (rf, vbs, expr) ->
        Sexp_let (rf,
                  List.map (sub.value_binding sub) vbs,
                  sub.expression sub expr)
    | Sexp_function cases ->
        Sexp_function (List.map (sub.case sub) cases)
    | Sexp_fun (label, expo, pat, expr) ->
        Sexp_fun (label,
                  map_opt (sub.expression sub) expo,
                  sub.pattern sub pat,
                  sub.expression sub expr)
    | Sexp_apply (f, args) ->
        Sexp_apply (sub.expression sub f,
                    List.map (map_snd @@ sub.expression sub) args)
    | Sexp_match (exp, cases) ->
        Sexp_match (sub.expression sub exp,
                    List.map (sub.case sub) cases)
    | Sexp_try (exp, cases) ->
        Sexp_try (sub.expression sub exp,
                  List.map (sub.case sub) cases)
    | Sexp_tuple exps ->
        Sexp_tuple (List.map (sub.expression sub) exps)
    | Sexp_construct (lid, expo) ->
        Sexp_construct (lid, map_opt (sub.expression sub) expo)
    | Sexp_record (fields, expo) ->
        Sexp_record (List.map (map_snd @@ sub.expression sub) fields,
                     map_opt (sub.expression sub) expo)
    | Sexp_field (exp, lid) ->
        Sexp_field (sub.expression sub exp, lid)
    | Sexp_setfield (e1, lid, e2) ->
        Sexp_setfield (sub.expression sub e1,
                       lid,
                       sub.expression sub e2)
    | Sexp_ifthenelse (e1, e2, e3) ->
        Sexp_ifthenelse (sub.expression sub e1,
                         sub.expression sub e2,
                         map_opt (sub.expression sub) e3)
    | Sexp_sequence (e1, e2) ->
        Sexp_sequence (sub.expression sub e1,
                       sub.expression sub e2)
    | Sexp_constraint (exp, typ) ->
        Sexp_constraint (sub.expression sub exp, typ)
    | Sexp_assert exp -> Sexp_assert (sub.expression sub exp)
    | Sexp_open (ovf, lid, exp) ->
        Sexp_open (ovf, lid, sub.expression sub exp)
    in
    {sexp_desc; sexp_env; sexp_type; sexp_loc; sexp_attrs}

  let pattern sub = function
    | Spat_any
    | Spat_var _
    | Spat_constant _ as pat -> pat
    | Spat_alias (pat, id, name) ->
        Spat_alias (sub.pattern sub pat, id, name)
    | Spat_tuple pats ->
        Spat_tuple (List.map (sub.pattern sub) pats)
    | Spat_construct (lid, pato) ->
        Spat_construct (lid, map_opt (sub.pattern sub) pato)
    | Spat_record (fields, cf) ->
        Spat_record (List.map (map_snd @@ sub.pattern sub) fields,
                     cf)
    | Spat_or (p1, p2) ->
        Spat_or (sub.pattern sub p1,
                 sub.pattern sub p2)
    | Spat_constraint (pat, typ) ->
        Spat_constraint (sub.pattern sub pat, typ)

  let case sub {sc_lhs; sc_guard; sc_rhs} =
    let sc_lhs = sub.pattern sub sc_lhs in
    let sc_guard = map_opt (sub.expression sub) sc_guard in
    let sc_rhs = sub.expression sub sc_rhs in
    {sc_lhs; sc_guard; sc_rhs}

  let value_binding sub {svb_pat; svb_expr} =
    let svb_pat = sub.pattern sub svb_pat in
    let svb_expr = sub.expression sub svb_expr in
    {svb_pat; svb_expr}

  let module_expr sub = function
    | Smod_ident lid -> Smod_ident lid
    | Smod_structure str ->
        Smod_structure (sub.structure sub str)
    | Smod_functor (name, mto, me) ->
        Smod_functor (name, mto, sub.module_expr sub me)
    | Smod_apply (me1, me2) ->
        Smod_apply (sub.module_expr sub me1,
                    sub.module_expr sub me2)
    | Smod_constraint (me, mt) ->
        Smod_constraint (sub.module_expr sub me, mt)

  let structure sub str =
    {str with
     sstr_items = List.map (sub.structure_item sub) str.sstr_items}

  let structure_item sub = function
    | Sstr_eval expr ->
        Sstr_eval (sub.expression sub expr)
    | Sstr_value (rf, vbs) ->
        Sstr_value (rf, List.map (sub.value_binding sub) vbs)
    | Sstr_module mb ->
        Sstr_module (sub.module_binding sub mb)
    | Sstr_primitive _
    | Sstr_type _
    | Sstr_exception _
    | Sstr_modtype _
    | Sstr_open _ as item -> item

  let module_binding sub {smb_name; smb_expr} =
    let smb_expr = sub.module_expr sub smb_expr in
    {smb_name; smb_expr}

  let default_mapper = {
    expression;
    pattern;
    case;
    value_binding;
    module_expr;
    structure;
    structure_item;
    module_binding;
  }

end

type 'a checker = {
  expression:     'a checker -> Typed_ast.expression -> 'a list;
  pattern:        'a checker -> Typed_ast.pattern -> 'a list;
  case:           'a checker -> Typed_ast.case -> 'a list;
  cases:          'a checker -> Typed_ast.case list -> 'a list;
  module_binding: 'a checker -> Typed_ast.module_binding -> 'a list;
  module_expr:    'a checker -> Typed_ast.module_expr -> 'a list;
  structure:      'a checker -> Typed_ast.structure -> 'a list;
  structure_item: 'a checker -> Typed_ast.structure_item -> 'a list;
  value_binding:  'a checker -> Asttypes.rec_flag -> Typed_ast.value_binding -> 'a list;
  value_bindings: 'a checker -> Asttypes.rec_flag -> Typed_ast.value_binding list -> 'a list;
}

module Typed_ast_checker = struct
  open Typed_ast

  let ast_check_expr checker =
    checker.expression checker

  let ast_check_structure checker =
    checker.structure checker

  (* The default checker *)

  (* Helpers *)
  let append_map f = List.fold_left (fun acc x -> acc @ (f x)) []
  let map_opt f = function
    | None -> []
    | Some x -> f x
  let map_snd f (_, x) = f x

  (* Default checker methods

     This could be implemented using Typed_ast_mapper instead of rewriting
     everything, but then we would need to provide functions for users to
     drive the recursion, and that would be messier in the long run.
   *)

  let expression sub expr = match expr.sexp_desc with
    | Sexp_ident _
    | Sexp_constant _ -> []
    | Sexp_let (rf, vbs, body) ->
        List.append
          (sub.value_bindings sub rf vbs)
          (sub.expression sub body)
    | Sexp_function cases -> sub.cases sub cases
    | Sexp_fun (_, expo, pat, body) ->
        List.append
          (map_opt (sub.expression sub) expo)
          (List.append
             (sub.pattern sub pat)
             (sub.expression sub body))
    | Sexp_apply (f, args) ->
        List.append
          (sub.expression sub f)
          (append_map (map_snd @@ sub.expression sub) args)
    | Sexp_match (exp, cases)
    | Sexp_try (exp, cases) ->
        List.append
          (sub.expression sub exp)
          (sub.cases sub cases)
    | Sexp_tuple exps -> append_map (sub.expression sub) exps
    | Sexp_construct (_, arg) -> map_opt (sub.expression sub) arg
    | Sexp_record (fields, template) ->
        (* The template report is likely to be empty, so for
           efficiency provide it as the first argument *)
        List.append
          (map_opt (sub.expression sub) template)
          (append_map (map_snd @@ sub.expression sub) fields)
    | Sexp_field (exp, _) -> sub.expression sub exp
    | Sexp_setfield (exp1, _, exp2) ->
        append_map (sub.expression sub) [exp1; exp2]
    | Sexp_ifthenelse (exp1, exp2, exp3) ->
        (* Students should almost never write a
           one-armed if, so swapping the order of
           reports isn't worth it *)
        List.append
          (append_map (sub.expression sub) [exp1; exp2])
          (map_opt (sub.expression sub) exp3)
    | Sexp_sequence (exp1, exp2) ->
        append_map (sub.expression sub) [exp1; exp2]
    | Sexp_constraint (exp, _) -> sub.expression sub exp
    | Sexp_assert exp -> sub.expression sub exp
    | Sexp_open (_, _, exp) -> sub.expression sub exp

  let pattern sub = function
    | Spat_any
    | Spat_var _
    | Spat_constant _ -> []
    | Spat_alias (pat, _, _) -> sub.pattern sub pat
    | Spat_tuple pats -> append_map (sub.pattern sub) pats
    | Spat_construct (_, pat) -> map_opt (sub.pattern sub) pat
    | Spat_record (pats, _) ->
        append_map (map_snd @@ sub.pattern sub) pats
    | Spat_or (pat1, pat2) ->
        append_map (sub.pattern sub) [pat1; pat2]
    | Spat_constraint (pat, _) -> sub.pattern sub pat

  let case sub {sc_lhs; sc_guard; sc_rhs} =
    List.append
      (sub.pattern sub sc_lhs)
      (List.append
         (map_opt (sub.expression sub) sc_guard)
         (sub.expression sub sc_rhs))

  let cases sub = append_map (sub.case sub)

  let structure sub str =
    append_map (sub.structure_item sub) str.sstr_items

  let structure_item sub = function
    | Sstr_eval exp -> sub.expression sub exp
    | Sstr_value (rf, vbs) -> sub.value_bindings sub rf vbs
    | Sstr_module mb -> sub.module_binding sub mb
    | Sstr_primitive _
    | Sstr_type _
    | Sstr_exception _
    | Sstr_modtype _
    | Sstr_open _ -> []

  let module_expr sub = function
    | Smod_ident _ -> []
    | Smod_structure str -> sub.structure sub str
    | Smod_functor (_, _, me) -> sub.module_expr sub me
    | Smod_apply (me1, me2) ->
        List.append
          (sub.module_expr sub me1)
          (sub.module_expr sub me2)
    | Smod_constraint (me, _) -> sub.module_expr sub me

  let module_binding sub {smb_expr = me; _} = sub.module_expr sub me

  let value_bindings sub rf vbs = append_map (sub.value_binding sub rf) vbs

  let value_binding sub _ {svb_pat = pat; svb_expr = expr; _} =
    List.append
      (sub.pattern sub pat)
      (sub.expression sub expr)

  let default_checker = {
    expression;
    pattern;
    case;
    cases;
    module_binding;
    module_expr;
    structure;
    structure_item;
    value_binding;
    value_bindings;
  }

end

(* Comparing Typed_asts while ignoring concrete strings, so that e.g.
   the scoped tree for "tl" in a context where the List module is opened
   is viewed as equal to the scoped tree for "List.tl".
   This also ignores location information.
 *)
module Typed_ast_compare = struct
  open Typed_ast

  module M = Ast_mapper
  let loc_stripper =
    let location _ _ = Location.none in
    let open M in
    {default_mapper with location}

  let compare_opt compare o1 o2 =
    match o1, o2 with
    | None, None -> true
    | Some v1, Some v2 -> compare v1 v2
    | _ -> false

  let compare_tuple2 compare_x compare_y (x1, y1) (x2, y2) =
    compare_x x1 x2 && compare_y y1 y2

  let compare_list compare l1 l2 =
    List.length l1 = List.length l2
    && List.for_all2 compare l1 l2

  let compare_lid {Asttypes.txt = lid1; _} {Asttypes.txt = lid2; _} =
    lid1 = lid2

  let compare_typ typ1 typ2 =
    let typ1 = loc_stripper.M.typ loc_stripper typ1 in
    let typ2 = loc_stripper.M.typ loc_stripper typ2 in
    typ1 = typ2

  let rec compare_expression e1 e2 =
    match e1.sexp_desc, e2.sexp_desc with
    | Sexp_ident (p1, _), Sexp_ident (p2, _) -> Path.same p1 p2
    | Sexp_constant c1, Sexp_constant c2 -> c1 = c2
    | Sexp_let (rf1, vbs1, e1), Sexp_let (rf2, vbs2, e2) ->
        rf1 = rf2
        && compare_value_bindings vbs1 vbs2
        && compare_expression e1 e2
    | Sexp_function cases1, Sexp_function cases2 ->
        compare_cases cases1 cases2
    | Sexp_fun (l1, expo1, pat1, e1), Sexp_fun (l2, expo2, pat2, e2) ->
        l1 = l2
        && compare_opt compare_expression expo1 expo2
        && compare_pattern pat1 pat2
        && compare_expression e1 e2
    | Sexp_apply (f1, args1), Sexp_apply (f2, args2) ->
        compare_expression f1 f2
        && compare_list (compare_tuple2 (=) compare_expression) args1 args2
    | Sexp_match (e1, cases1), Sexp_match (e2, cases2) ->
        compare_expression e1 e2
        && compare_cases cases1 cases2
    | Sexp_try (e1, cases1), Sexp_try (e2, cases2) ->
        compare_expression e1 e2
        && compare_cases cases1 cases2
    | Sexp_tuple e1, Sexp_tuple e2 ->
        compare_list compare_expression e1 e2
    | Sexp_construct (lid1, expo1), Sexp_construct (lid2, expo2) ->
        compare_lid lid1 lid2
        && compare_opt compare_expression expo1 expo2
    | Sexp_record (fields1, expo1), Sexp_record (fields2, expo2) ->
        compare_list
          (compare_tuple2 compare_lid compare_expression)
          fields1
          fields2
        && compare_opt compare_expression expo1 expo2
    | Sexp_field (e1, lid1), Sexp_field (e2, lid2) ->
        compare_expression e1 e2
        && compare_lid lid1 lid2
    | Sexp_setfield (e11, lid1, e12), Sexp_setfield (e21, lid2, e22) ->
        compare_expression e11 e21
        && compare_lid lid1 lid2
        && compare_expression e12 e22
    | Sexp_ifthenelse (e11, e12, e13), Sexp_ifthenelse (e21, e22, e23) ->
        compare_expression e11 e21
        && compare_expression e12 e22
        && compare_opt compare_expression e13 e23
    | Sexp_sequence (e11, e12), Sexp_sequence (e21, e22) ->
        compare_expression e11 e21
        && compare_expression e12 e22
    | Sexp_constraint (e1, typ1), Sexp_constraint (e2, typ2) ->
        compare_expression e1 e2
        && compare_typ typ1 typ2
    | Sexp_assert e1, Sexp_assert e2 ->
        compare_expression e1 e2
    | Sexp_open (ovf1, lid1, e1), Sexp_open (ovf2, lid2, e2) ->
        ovf1 = ovf2
        && compare_lid lid1 lid2
        && compare_expression e1 e2
    | _ -> false

  and compare_value_binding {svb_pat = p1; svb_expr = e1} {svb_pat = p2; svb_expr = e2} =
    compare_pattern p1 p2
    && compare_expression e1 e2

  and compare_value_bindings vbs1 vbs2 =
    compare_list compare_value_binding vbs1 vbs2

  and compare_case
      {sc_lhs = lhs1; sc_guard = g1; sc_rhs = rhs1}
      {sc_lhs = lhs2; sc_guard = g2; sc_rhs = rhs2} =
    compare_pattern lhs1 lhs2
    && compare_opt compare_expression g1 g2
    && compare_expression rhs1 rhs2

  and compare_cases cases1 cases2 =
    compare_list compare_case cases1 cases2

  and compare_pattern p1 p2 =
    match p1, p2 with
    | Spat_any, Spat_any -> true
    | Spat_var (id1, _), Spat_var (id2, _) -> Ident.same id1 id2
    | Spat_alias (p1, id1, _), Spat_alias (p2, id2, _) ->
        Ident.same id1 id2
        && compare_pattern p1 p2
    | Spat_constant c1, Spat_constant c2 -> c1 = c2
    | Spat_tuple pats1, Spat_tuple pats2 ->
        compare_list compare_pattern pats1 pats2
    | Spat_construct (lid1, pato1), Spat_construct (lid2, pato2) ->
        compare_lid lid1 lid2
        && compare_opt compare_pattern pato1 pato2
    | Spat_record (fields1, cf1), Spat_record (fields2, cf2) ->
        compare_list (compare_tuple2 compare_lid compare_pattern) fields1 fields2
        && cf1 = cf2
    | Spat_or (p11, p12), Spat_or (p21, p22) ->
        compare_pattern p11 p21
        && compare_pattern p12 p22
    | Spat_constraint (p1, typ1), Spat_constraint (p2, typ2) ->
        compare_pattern p1 p2
        && compare_typ typ1 typ2
    | _ -> false

end

module Typed_ast_height = struct
  open Typed_ast

  let rec exp_height exp =
    match exp.sexp_desc with
    | Sexp_ident _
    | Sexp_constant _ -> 1
    | Sexp_let (_, vbs, expr) ->
        let h1 = exp_height expr in
        let h' =
          List.fold_left
            (fun acc vb -> max acc (vb_height vb))
            h1
            vbs
        in
        1 + h'
    | Sexp_function cases ->
        let h' =
          List.fold_left
            (fun acc case -> max acc (case_height case))
            0
            cases
        in
        1 + h'
    | Sexp_fun (_, expo, pat, expr) ->
        let h1 = pat_height pat in
        let h2 = exp_height expr in
        let h' = max h1 h2 in
        begin
          match expo with
          | None -> 1 + h'
          | Some exp ->
              let h3 = exp_height exp in
              1 + max h' h3
        end
    | Sexp_apply (expr, args) ->
        let h1 = exp_height expr in
        let h' =
          List.fold_left
            (fun acc (_, exp) -> max acc (exp_height exp))
            h1
            args
        in
        1 + h'
    | Sexp_match (expr, cases)
    | Sexp_try (expr, cases) ->
        let h1 = exp_height expr in
        let h' =
          List.fold_left
            (fun acc case -> max acc (case_height case))
            h1
            cases
        in
        1 + h'
    | Sexp_tuple exps ->
        let h' =
          List.fold_left
            (fun acc exp -> max acc (exp_height exp))
            0
            exps
        in
        1 + h'
    | Sexp_construct (_, None) -> 1
    | Sexp_construct (_, Some exp) -> 1 + exp_height exp
    | Sexp_record (fields, expo) ->
        let h' =
          List.fold_left
            (fun acc (_, exp) -> max acc (exp_height exp))
            0
            fields
        in
        begin
          match expo with
          | None -> 1 + h'
          | Some exp ->
              let h1 = exp_height exp in
              1 + max h' h1
        end
    | Sexp_field (exp, _) -> 1 + exp_height exp
    | Sexp_setfield (e1, _, e2) ->
        1 + max (exp_height e1) (exp_height e2)
    | Sexp_ifthenelse (e1, e2, expo) ->
        let h1 = exp_height e1 in
        let h2 = exp_height e2 in
        let h' = max h1 h2 in
        begin
          match expo with
          | None -> 1 + h'
          | Some exp ->
              let h3 = exp_height exp in
              1 + max h' h3
        end
    | Sexp_sequence (e1, e2) ->
        1 + max (exp_height e1) (exp_height e2)
    | Sexp_constraint (exp, _)
    | Sexp_assert exp
    | Sexp_open (_, _, exp) -> 1 + exp_height exp

  and pat_height pat =
    match pat with
    | Spat_any
    | Spat_var _
    | Spat_constant _ -> 1
    | Spat_alias (pat, _, _) -> 1 + pat_height pat
    | Spat_tuple pats ->
        let h' =
          List.fold_left
            (fun acc pat -> max acc (pat_height pat))
            0
            pats
        in
        1 + h'
    | Spat_construct (_, None) -> 1
    | Spat_construct (_, Some pat) -> 1 + pat_height pat
    | Spat_record (fields, _) ->
        let h' =
          List.fold_left
            (fun acc (_, pat) -> max acc (pat_height pat))
            0
            fields
        in
        1 + h'
    | Spat_or (p1, p2) ->
        let h1 = pat_height p1 in
        let h2 = pat_height p2 in
        1 + max h1 h2
    | Spat_constraint (pat, _) -> 1 + pat_height pat

  and vb_height {svb_pat; svb_expr} =
    1 + max (pat_height svb_pat) (exp_height svb_expr)

  and case_height {sc_lhs; sc_guard; sc_rhs} =
    let h1 = pat_height sc_lhs in
    let h2 = exp_height sc_rhs in
    let h' = max h1 h2 in
    match sc_guard with
    | None -> 1 + h'
    | Some exp ->
        let h3 = exp_height exp in
        1 + max h' h3
end

module Typed_ast_fragments = struct
  open Typed_ast

  let tast_of_desc sexp_desc =
    {sexp_desc;
     sexp_env = Env.empty;
     sexp_type = Predef.type_unit;
     sexp_loc = Location.none;
     sexp_attrs = []}

  let structure_of_item item =
    {sstr_items = [item];
     sstr_type = [];
     sstr_env = Env.empty}

  let path_of_id id =
    let open PtoS in
    init_env ();
    lookup_lid (Longident.parse id)

  let tast_expr_of_ident id =
    tast_of_desc @@
    Sexp_ident (Path.Pident id,
                loc (Longident.Lident (Ident.name id)))

  let tast_pat_of_ident id =
    Spat_var (id, loc (Ident.name id))

  let empty_list_lid = loc (Longident.Lident "[]")
  let cons_lid = loc (Longident.Lident "::")

  let rec to_list constr tuple xs =
    match xs with
    | [] -> constr (empty_list_lid, None)
    | x :: xs ->
        let xs' = to_list constr tuple xs in
        constr (cons_lid, Some (tuple [x; xs']))

  let list_pat =
    to_list
      (fun (lid, pato) -> Spat_construct (lid, pato))
      (fun pats -> Spat_tuple pats)

  let list_expr =
    to_list
      (fun (lid, expo) -> tast_of_desc (Sexp_construct (lid, expo)))
      (fun exps -> tast_of_desc (Sexp_tuple exps))

  let cons_pat p1 p2 =
    Spat_construct (cons_lid,
                    Some (Spat_tuple [p1; p2]))

  let cons_expr e1 e2 =
    tast_of_desc @@
    Sexp_construct (
      cons_lid,
      Some (tast_of_desc (Sexp_tuple [e1; e2])))

  let apply_expr f args =
    tast_of_desc @@
       Sexp_apply (f,
                   List.map (fun arg -> (Asttypes.Nolabel, arg)) args)

  let match_expr expr cases =
    tast_of_desc (Sexp_match (expr, cases))

end

let tast_of_parsetree_structure str =
  let open PtoS in
  init_env ();
  structure str

let tast_of_parsetree_pattern = PtoS.pat

let tast_of_parsetree_expression expr =
  let open PtoS in
  init_env ();
  expression expr

let parsetree_of_tast_expression =
  let open StoP in
  default_mapper.expression default_mapper

(* Create our own formatters for pretty-printing ASTs,
   so we can set smaller margins to avoid code being
   all on one line.
 *)
let pp_buffer = Buffer.create 512
let ppf = Format.formatter_of_buffer pp_buffer
let () = Format.pp_set_margin ppf 40 (* default is 80 *)
let flush_buffer () = begin
  Format.pp_print_flush ppf ();
  let s = Buffer.contents pp_buffer in
  Buffer.reset pp_buffer;
  s
end

let string_of_tast_structure ?(unique_ids=false) str =
  let open StoP in
  let mapper = if unique_ids then unique_id_mapper else default_mapper in
  mapper.structure mapper str
  |> Pprintast.structure ppf;
  flush_buffer ()

let string_of_tast_expression ?(unique_ids=false) exp =
  let open StoP in
  let mapper = if unique_ids then unique_id_mapper else default_mapper in
  mapper.expression mapper exp
  |> Pprintast.expression ppf;
  flush_buffer ()

let replace (e', e) =
  let open Typed_ast_mapper in
  let expression replaced sub exp =
    if Typed_ast_compare.compare_expression e exp
    then begin
      replaced := true; e'
    end
    else default_mapper.expression sub exp
  in
  fun exp ->
    let replaced = ref false in
    let expression = expression replaced in
    let mapper = {default_mapper with expression} in
    let result = mapper.expression mapper exp in
    (!replaced, result)

module VarSet = Set.Make(Path)
module StringSet = Set.Make(String)

let lid_to_string lid = String.concat "." (Longident.flatten lid)

let variable_names =
  let open Typed_ast_checker in
  let open Typed_ast in
  let expression vars sub expr =  match expr.sexp_desc with
    | Sexp_ident (_, {Asttypes.txt; _}) ->
        begin
          vars := StringSet.add (lid_to_string txt) !vars;
          []
        end
    | _ -> default_checker.expression sub expr
  in
  let pattern vars sub = function
    | Spat_var (_, {Asttypes.txt; _}) ->
        begin
          vars := StringSet.add txt !vars;
          []
        end
    | Spat_alias (pat, _, {Asttypes.txt; _}) ->
        begin
          vars := StringSet.add txt !vars;
          sub.pattern sub pat
        end
    | pat -> default_checker.pattern sub pat
  in
  fun expr ->
    let vars = ref StringSet.empty in
    let expression = expression vars in
    let pattern = pattern vars in
    let checker = {default_checker with expression; pattern} in
    begin
      ignore (checker.expression checker expr);
      !vars
    end

let variables =
  let open Typed_ast_checker in
  let open Typed_ast in
  let expression vars sub expr = match expr.sexp_desc with
    | Sexp_ident (var, _) ->
        begin
          vars := VarSet.add var !vars;
          []
        end
    | _ -> default_checker.expression sub expr
  in
  let pattern vars sub = function
    | Spat_var (id, _) ->
        begin
          vars := VarSet.add (Path.Pident id) !vars;
          []
        end
    | Spat_alias (pat, id, _) ->
        begin
          vars := VarSet.add (Path.Pident id) !vars;
          sub.pattern sub pat
        end
    | pat -> default_checker.pattern sub pat
  in
  fun expr ->
    let vars = ref VarSet.empty in
    let expression = expression vars in
    let pattern = pattern vars in
    let checker = {default_checker with expression; pattern} in
    begin
      ignore (checker.expression checker expr);
      !vars
    end

let bound_variable_checker =
  let open Typed_ast_checker in
  let open Typed_ast in
  let pattern vars sub = function
    | Spat_var (id, _) ->
        begin
          vars := VarSet.add (Path.Pident id) !vars;
          []
        end
    | Spat_alias (pat, id, _) ->
        begin
          vars := VarSet.add (Path.Pident id) !vars;
          sub.pattern sub pat
        end
    | pat -> default_checker.pattern sub pat
  in
  fun () ->
    let vars = ref VarSet.empty in
    let pattern = pattern vars in
    let checker = {default_checker with pattern} in
    (vars, checker)

let variables_bound_by_pattern pat =
  let (vars, checker) = bound_variable_checker () in
  begin
    ignore (checker.pattern checker pat);
    !vars
  end

let check_bound_vars fn ast =
  let (vars, checker) = bound_variable_checker () in
  begin
    ignore ((fn checker) checker ast);
    !vars
  end

let bound_variables =
  check_bound_vars (fun checker -> checker.expression)

let free_variables expr =
  VarSet.diff (variables expr) (bound_variables expr)

let default_checker = Typed_ast_checker.default_checker
let ast_check_expr = Typed_ast_checker.ast_check_expr
let ast_check_structure = Typed_ast_checker.ast_check_structure

(* Messages copied from test_lib *)
let could_not_find_binding name =
  let open Learnocaml_report in
  [Message ([Text "I could not find "; Code name; Text ".";
             Break;
             Text "Check that it is defined as a simple "; Code "let";
             Text " at top level."], Failure)]
let found_binding name =
  let open Learnocaml_report in
  Message ([Text "Found a toplevel definition for "; Code name; Text "."],
           Informative)

let find_binding sstr name f =
  let open Typed_ast in
  let rec find_let = function
    | [] -> could_not_find_binding name

    | Sstr_value (rf, vbs) :: tl ->
        let rec find_var = function
          | [] -> find_let tl
          | {svb_pat = Spat_var (id, {Asttypes.txt; _}); svb_expr} :: _
            when txt = name ->
              found_binding name :: f rf (Path.Pident id) svb_expr
          | _ :: tl -> find_var tl
        in
        find_var vbs

    | _ :: tl -> find_let tl
  in
  find_let (List.rev sstr.sstr_items)

type expr_result = {
  expr: Typed_ast.expression;
  parent: Typed_ast.expression option
}

(* If opt is None, call the continuation,
   otherwise return opt.
*)
let (>>>) opt cont =
  match opt with
  | None -> cont ()
  | _ -> opt

let fold_opt f =
  List.fold_left
    (fun acc x -> acc >>> (fun () -> f x))
    None

let maybe_fill_parent result expr =
  match result with
  | Some ({parent = None; _} as result) ->
      Some {result with parent = Some expr}
  | _ -> result

let line_number loc =
  let ln = loc.Location.loc_start.Lexing.pos_lnum in
  string_of_int ln

let check_tailcalls var =
  let open Typed_ast in
  let is_id_call expr =
    match expr.sexp_desc with
    | Sexp_apply (f, _) ->
        begin
          match f.sexp_desc with
          | Sexp_ident (var', _) -> Path.same var var'
          | _ -> false
        end
    | _ -> false
  in
  let rec exists_call expr () : expr_result option =
    if is_id_call expr then
      Some {expr; parent = None}
    else
      let result =
        match expr.sexp_desc with
        | Sexp_let (_, vbs, exp) ->
            fold_opt exists_call_vb vbs
            >>> exists_call exp
        | Sexp_function cases ->
            fold_opt exists_call_case cases
        | Sexp_fun (_, expo, _, exp) ->
            exists_call exp ()
            >>> exists_call_opt expo
        | Sexp_apply (f, args) ->
            let in_args =
              fold_opt (fun (_, exp) -> exists_call exp ()) args
            in
            in_args >>> exists_call f
        | Sexp_match (exp, cases) ->
            fold_opt exists_call_case cases
            >>> exists_call exp
        | Sexp_try (exp, cases) ->
            fold_opt exists_call_case cases
            >>> exists_call exp
        | Sexp_tuple exps ->
            fold_opt (fun exp -> exists_call exp ()) exps
        | Sexp_construct (_, Some exp) -> exists_call exp ()
        | Sexp_record (fields, expo) ->
            let in_fields =
              fold_opt (fun (_, exp) -> exists_call exp ()) fields
            in
            in_fields >>> exists_call_opt expo
        | Sexp_field (exp, _) -> exists_call exp ()
        | Sexp_setfield (exp1, _, exp2) ->
            exists_call exp1 ()
            >>> exists_call exp2
        | Sexp_ifthenelse (exp1, exp2, expo) ->
            exists_call exp1 ()
            >>> exists_call exp2
            >>> exists_call_opt expo
        | Sexp_sequence (exp1, exp2) ->
            exists_call exp1 ()
            >>> exists_call exp2
        | Sexp_constraint (exp, _) -> exists_call exp ()
        | Sexp_assert exp -> exists_call exp ()
        | Sexp_open (_, _, exp) -> exists_call exp ()
        | _ -> None
      in
      maybe_fill_parent result expr

  and exists_call_vb {svb_expr; _} = exists_call svb_expr ()

  and exists_call_case {sc_guard; sc_rhs; _} =
    exists_call_opt sc_guard ()
    >>> exists_call sc_rhs

  and exists_call_opt expo () =
    match expo with
    | None -> None
    | Some exp -> exists_call exp ()

  in
  let rec check expr () : expr_result option =
    let result =
      match expr.sexp_desc with
      | Sexp_let (_, vbs, exp) ->
          fold_opt exists_call_vb vbs
          >>> check exp
      | Sexp_function cases ->
          fold_opt check_case cases
      | Sexp_fun (_, expo, _, exp) ->
          exists_call_opt expo ()
          >>> check exp
      | Sexp_apply (f, args) ->
          let in_args =
            fold_opt (fun (_, arg) -> exists_call arg ()) args
          in
          in_args >>> exists_call f
      | Sexp_match (exp, cases) ->
          fold_opt check_case cases
          >>> exists_call exp
      | Sexp_try (exp, cases) ->
          fold_opt check_case cases
          >>> exists_call exp
      | Sexp_tuple exps ->
          fold_opt (fun exp -> exists_call exp ()) exps
      | Sexp_construct (_, expo) ->
          exists_call_opt expo ()
      | Sexp_record (fields, expo) ->
          let in_fields =
            fold_opt (fun (_, exp) -> exists_call exp ()) fields
          in
          in_fields
          >>> exists_call_opt expo
      | Sexp_field (exp, _) -> exists_call exp ()
      | Sexp_setfield (exp1, _, exp2) ->
          exists_call exp1 ()
          >>> exists_call exp2
      | Sexp_ifthenelse (exp1, exp2, expo) ->
          exists_call exp1 ()
          >>> check exp2
          >>> check_opt expo
      | Sexp_sequence (exp1, exp2) ->
          exists_call exp1 ()
          >>> check exp2
      | Sexp_constraint (exp, _) -> check exp ()
      | Sexp_assert exp -> exists_call exp ()
      | Sexp_open (_, _, exp) -> check exp ()
      | _ -> None
    in
    maybe_fill_parent result expr

  and check_case {sc_guard; sc_rhs; _} =
    exists_call_opt sc_guard ()
    >>> check sc_rhs

  and check_opt expo () =
    match expo with
    | None -> None
    | Some exp -> check exp ()

  in
  fun ?(points=1) expr ->
    let open Learnocaml_report in
    match check expr () with
    | None ->
        [Message (
            [Text "All calls to";
             Code (Path.name var);
             Text "are tail calls"
            ],
            if points = 0 then Important else Success points)]

    | Some {expr; parent} ->
        let suffix =
          match parent with
          | None -> (* this should never happen, but just in case *)
              [Text ":";
               Break;
               Code (string_of_tast_expression expr)]

          | Some parent ->
              [Text " because it appears in the following context:";
               Break;
               Code (string_of_tast_expression parent)]
        in
        let line = line_number expr.sexp_loc in
        [Message (
            [Text ("On line " ^ line ^ ", ");
             Text "found a call to";
             Code (Path.name var);
             Text "that is not in tail position"]
            @ suffix,
            Failure)]

let same_expr = Typed_ast_compare.compare_expression
let same_pattern = Typed_ast_compare.compare_pattern

let expr_height = Typed_ast_height.exp_height

let lookup_in_expr_env =
  let open Typed_ast in
  fun {sexp_env; _} id ->
    fst @@ Env.lookup_value (Longident.parse id) sexp_env

(* Helpers for constructing Typed_ast fragments *)
let tast_of_desc = Typed_ast_fragments.tast_of_desc
let structure_of_item = Typed_ast_fragments.structure_of_item

let path_of_id = Typed_ast_fragments.path_of_id

let soln_path tast id =
  let path = ref None in
  let _ =
    find_binding tast id @@ fun _ p _ ->
    path := Some p; []
  in
  match !path with
  | None -> raise Not_found
  | Some path -> path

let tast_expr_of_ident =
  Typed_ast_fragments.tast_expr_of_ident
let tast_pat_of_ident =
  Typed_ast_fragments.tast_pat_of_ident

let list_pat = Typed_ast_fragments.list_pat
let list_expr = Typed_ast_fragments.list_expr
let cons_pat = Typed_ast_fragments.cons_pat
let cons_expr = Typed_ast_fragments.cons_expr
let apply_expr = Typed_ast_fragments.apply_expr
let match_expr = Typed_ast_fragments.match_expr

module Dependencies = struct
  open Typed_ast

  (* Comparing Paths, for graphs *)
  module ComparablePath : (Graph.Sig.COMPARABLE with type t = Path.t) = struct
    type t = Path.t
    let compare = Path.compare
    let equal = Path.same
    let hash = Hashtbl.hash
  end

  module G = Graph.Imperative.Digraph.Concrete(ComparablePath)
  module Q = Queue
  let string_of_path = Path.name

  type dep_graph = G.t

  (* Traverse graph [g] in a breadth-first fashion from vertex [v].
     Do *not* traverse past vertices indicated in the list [stop_at].
     Return a list of all vertices visited.
     v will be present in the return list *only* if there is a
     cycle in g leading back to v.
  *)
  let bfs g ~stop_at v =
    let stop_at = VarSet.of_list stop_at in
    let q: Path.t Q.t = Q.create () in
    let deps = ref (VarSet.empty) in
    Q.push v q;
    while not (Q.is_empty q) do
      let v = Q.pop q in
      G.iter_succ
        (fun u ->
           if not (VarSet.mem u !deps) then
             begin
               deps := VarSet.add u !deps;
               if not (VarSet.mem u stop_at) then
                 Q.push u q
             end)
        g
        v
    done;
    VarSet.fold (fun (v: Path.t) l -> v :: l) !deps []

  (* Traverse graph g in a breadth-first fashion, starting
     from the vertices in the list of vertices init.
     Return a set of the *sinks* (i.e., vertices with
     no outgoing edges) reachable from the vertices in
     init.
  *)
  let bfs' g init =
    let q: Path.t Q.t = Q.create () in
    let results = ref (VarSet.empty) in
    let marked = ref VarSet.empty in
    VarSet.iter
      (fun v -> Q.push v q)
      init;
    while not (Q.is_empty q) do
      let v = Q.pop q in
      marked := VarSet.add v !marked;
      if (G.out_degree g v) = 0 then
        results := VarSet.add v !results
      else
        G.iter_succ
          (fun u ->
             if not (VarSet.mem u !marked) then
               begin
                 marked := VarSet.add u !marked;
                 Q.push u q
               end)
          g
          v
    done;
    !results

  (* Return a set of the *free* variables (relative to expr)
     used by expr.
     By "used", we mean "not unused", i.e. for an expression
     [let _ = e1 in e2], the free variables in [e1] are *not*
     counted as used.
     This analysis does not take into account any possible
     side effects of expressions.
     It is neither sound nor complete:
     - A variable may sometimes be erroneously reported as being
       used because we do not work too hard to get around some
       ways students may try to trick us, e.g. by creating a
       function that doesn't use its arguments and then
       calling that function on some variables that they
       desire to mark "used".
     - A variable may appear to be unused because it is part
       of an expression that is called only for its side
       effect, with the result being discarded.
       At present these drawbacks seem acceptable for our purposes.
  *)
  let rec used_variables expr =
    match expr.sexp_desc with
    | Sexp_ident (var, _) -> VarSet.singleton var
    | Sexp_constant _ -> VarSet.empty
    | Sexp_let (_, vbs, body) ->
        (* Invariant: vars contains ONLY free variables
           and variables bound by vbs *)
        let vars = used_variables body in
        (* Set of variables bound by vbs *)
        let bvs =
          List.fold_left
            (fun set {svb_pat; _} ->
               let bvs = variables_bound_by_pattern svb_pat in
               VarSet.union set bvs)
            VarSet.empty
            vbs
        in
        (* Create a dependency graph for the bvs *)
        let g = G.create () in
        List.iter (treat_vb g) vbs;
        (* Find the free variables that the bvs depend on. *)
        let vb_vars = bfs' g (VarSet.inter vars bvs) in
        (* Don't return the bvs themselves, because they aren't
           free variables. *)
        VarSet.diff (VarSet.union vars vb_vars) bvs
    | Sexp_function cases ->
        List.fold_left
          (fun set case -> VarSet.union set (treat_case case))
          VarSet.empty
          cases
    (* Ignoring optional/labelled arguments for now *)
    | Sexp_fun (_, _, pat, body) ->
        let bvs = variables_bound_by_pattern pat in
        let used_vars = used_variables body in
        VarSet.diff used_vars bvs
    | Sexp_apply (exp, exps) ->
        List.fold_left
          (fun set (_, exp) -> VarSet.union set (used_variables exp))
          (used_variables exp)
          exps
    | Sexp_match (exp, cases)
    | Sexp_try (exp, cases) ->
        List.fold_left
          (fun set case -> VarSet.union set (treat_case case))
          (used_variables exp)
          cases
    | Sexp_tuple exps ->
        List.fold_left
          (fun set exp -> VarSet.union set (used_variables exp))
          VarSet.empty
          exps
    | Sexp_construct (_, None) -> VarSet.empty
    | Sexp_construct (_, Some exp) -> used_variables exp
    | Sexp_record (fields, expo) ->
        let field_vars =
          List.fold_left
            (fun set (_, exp) -> VarSet.union set (used_variables exp))
            VarSet.empty
            fields
        in
        begin
          match expo with
          | None -> field_vars
          | Some exp -> VarSet.union field_vars (used_variables exp)
        end
    | Sexp_field (exp, _) -> used_variables exp
    | Sexp_setfield (exp1, _, exp2) ->
        VarSet.union (used_variables exp1) (used_variables exp2)
    | Sexp_ifthenelse (e1, e2, expo) ->
        let used_vars = VarSet.union (used_variables e1) (used_variables e2) in
        begin
          match expo with
          | None -> used_vars
          | Some exp -> VarSet.union used_vars (used_variables exp)
        end
    | Sexp_sequence (exp1, exp2) ->
        VarSet.union (used_variables exp1) (used_variables exp2)
    | Sexp_constraint (exp, _) -> used_variables exp
    | Sexp_assert exp -> used_variables exp
    | Sexp_open (_, _, exp) -> used_variables exp

  and treat_vb g {svb_pat; svb_expr} =
    let bvs = variables_bound_by_pattern svb_pat in
    let used_vars = used_variables svb_expr in
    VarSet.iter
      (fun var ->
         G.add_vertex g var;
         VarSet.iter (G.add_edge g var) used_vars)
      bvs

  and treat_case {sc_lhs; sc_guard; sc_rhs} =
    let bvs = variables_bound_by_pattern sc_lhs in
    let used_vars_body = used_variables sc_rhs in
    let used_vars =
      match sc_guard with
      | None -> used_vars_body
      | Some exp -> VarSet.union used_vars_body (used_variables exp)
    in
    VarSet.diff used_vars bvs

  (* Given a Typed AST structure, return a dependency graph
     for the top-level definitions. Vertices in this graph
     can be top-level variables or built-ins (including variables
     defined in the prelude). A (directed) edge exists between
     variables v1 and v2 if v1 "depends" on v2, meaning v2 is
     used somewhere in the definition of v1, either directly
     or transitively through use of another variable that
     depends on v2.
  *)
  let dep_graph str =
    let g = G.create () in
    let deps_vb {svb_pat; svb_expr} =
      let ids = variables_bound_by_pattern svb_pat in
      let free_vars =
        used_variables svb_expr
      in
      VarSet.iter
        (fun var ->
           VarSet.iter
             (fun dep_var -> G.add_edge g var dep_var)
             free_vars)
        ids
    in
    let deps item =
      match item with
      | Sstr_value (_, vbs) -> List.iter deps_vb vbs
      | _ -> ()
    in
    List.iter deps str.sstr_items;
    g

  (* Given a dependency graph [g] and two variables (type [Path.t]),
     return [true] iff the vertex corresponding to [dep] is reachable
     from the vertex corresponding to [var] in [g]. If [var] does not
     exist as a vertex in [g], return [false].
     Does not propagate the transitive dependencies of variables
     specified by optional argument [dont_propagate].
  *)
  let depends_on g ?(dont_propagate = []) var dep =
    if G.mem_vertex g var then
      let deps = bfs g ~stop_at: dont_propagate var in
      List.mem dep deps
    else
      false (* or error? *)

  (* Given a dependency graph [g] and a variable (type [Path.t]) [var],
     return a list of variables that [var] depends on. [var] should be a
     vertex in [g]. If [var] is not a vertex in [g], the result is the
     empty list.
     Does not propagate the transitive dependencies of variables
     specified by optional argument [dont_propagate].
  *)
  let dependencies g ?(dont_propagate = []) var =
    if G.mem_vertex g var then
      bfs g ~stop_at: dont_propagate var
    else
      []

  (* For debugging purposes: return a string representation
     of the vertices and edges in the dependency graph [g].
  *)
  let dump_deps g =
    let vs =
      G.fold_vertex
        (fun v l -> (string_of_path v) :: l)
        g []
    in
    let es =
      G.fold_edges
        (fun v1 v2 l -> (string_of_path v1, string_of_path v2) :: l)
        g []
    in
    let v_str = List.fold_left (fun str s -> str ^ "\n" ^ s) "" vs in
    let e_str =
      List.fold_left
        (fun str (s1, s2) -> str ^ "\n(" ^ s1 ^ ", " ^ s2 ^ ")")
        "" es
    in
    let v_str = "VERTICES:\n" ^ v_str in
    let e_str = "EDGES:\n" ^ e_str in
    v_str ^ "\n\n" ^ e_str

end

type dep_graph = Dependencies.dep_graph
let dependency_graph = Dependencies.dep_graph
let depends_on = Dependencies.depends_on
let dependencies = Dependencies.dependencies
let dump_deps = Dependencies.dump_deps
