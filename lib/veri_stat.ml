open Core_kernel.Std
open Regular.Std

module Calls = String.Map

type ok_er = int * int [@@deriving bin_io, compare, sexp]

type t = {
  calls : ok_er Calls.t;
  errors: Veri_error.t list;
} [@@deriving bin_io, compare, sexp]

type stat = t [@@deriving bin_io, compare, sexp]

let create () = { calls = Calls.empty; errors = []; }
let errors t = t.errors
let notify t er = {t with errors = er :: t.errors }

let update t name ~ok ~er = 
  {t with 
   calls =
     Map.change t.calls name
       (function 
         | None -> Some (ok, er)
         | Some (ok',er') -> Some (ok + ok', er + er')) } 

let failbil t name = update t name ~ok:0 ~er:1
let success t name = update t name ~ok:1 ~er:0

let merge s s' = 
  let errors = s.errors @ s'.errors in
  let calls = Map.fold ~init:s.calls s'.calls
      ~f:(fun ~key ~data calls ->
          Map.change calls key ~f:(function
              | None -> Some data
              | Some (ok,er) -> Some (fst data + ok, snd data + er))) in
  {errors; calls}

module Abs = struct

  type nonrec t = t -> int

  let fold_calls {calls} f = Map.fold ~f ~init:0 calls

  let errors_count t = 
    let rec loop ((ovr, dmg, undis, misl) as acc) = function
      | [] -> acc
      | hd :: tl -> match hd with 
        | `Overloaded_chunk -> loop (ovr + 1, dmg, undis, misl) tl
        | `Damaged_chunk  _ -> loop (ovr, dmg + 1, undis, misl) tl
        | `Disasm_error   _ -> loop (ovr, dmg, undis + 1, misl) tl
        | `Lifter_error   _ -> loop (ovr, dmg, undis, misl + 1) tl in
    loop (0,0,0,0) t.errors

  let overloaded  t = let x,_,_,_ = errors_count t in x
  let damaged     t = let _,x,_,_ = errors_count t in x
  let undisasmed  t = let _,_,x,_ = errors_count t in x
  let mislifted   t = let _,_,_,x = errors_count t in x
  let successed   t = fold_calls t (fun ~key ~data cnt -> cnt + fst data)
  let misexecuted t = fold_calls t (fun ~key ~data cnt -> cnt + snd data)

  let abs_successed t = 
    fold_calls t (fun ~key ~data cnt ->
        if snd data <> 0 then cnt
        else cnt + fst data)
      
  let abs_misexecuted t = 
    fold_calls t (fun ~key ~data cnt ->   
      if fst data <> 0 then cnt 
      else cnt + snd data)

  let total t = 
    List.length t.errors + 
    fold_calls t (fun ~key ~data cnt -> cnt + fst data + snd data)

end


module Rel = struct
  type t = stat -> float  
  let total = Abs.total
  let to_percent f t  = float (f t) /. float (total t) *. 100.0
  let successed       = to_percent Abs.successed
  let abs_successed   = to_percent Abs.abs_successed
  let misexecuted     = to_percent Abs.misexecuted
  let abs_misexecuted = to_percent Abs.abs_misexecuted
  let overloaded      = to_percent Abs.overloaded
  let damaged         = to_percent Abs.damaged
  let undisasmed      = to_percent Abs.undisasmed
  let mislifted       = to_percent Abs.mislifted
end

module Names = struct

  type nonrec t = t -> string list

  let fold_calls ~condition t =
    Map.fold ~f:(fun ~key ~data names -> 
        if condition data then Set.add names key
        else names) ~init:String.Set.empty t.calls |>
    Set.to_list

  let successed = fold_calls ~condition:(fun data -> fst data <> 0)
  let abs_successed = fold_calls ~condition:(fun data -> snd data = 0)
  let misexecuted = fold_calls ~condition:(fun data -> snd data <> 0)
  let abs_misexecuted = fold_calls ~condition:(fun data -> fst data = 0)

  let mislifted t = 
    List.fold_left ~init:String.Set.empty 
      ~f:(fun names errs ->
          match errs with 
          | `Lifter_error (insn,_) -> Set.add names insn
          | _ -> names) t.errors |>
    Set.to_list
end

let print_table fmt info data = 
  let open Textutils.Std in
  let open Ascii_table in
  let cols = 
    List.fold ~f:(fun acc (name, f) -> 
        (Column.create name f)::acc) ~init:[] info |> List.rev in
  Format.fprintf fmt "%s"
    (to_string ~bars:`Ascii ~display:Display.short_box cols data)

module R = Regular.Make(struct
    type nonrec t = t [@@deriving bin_io, compare, sexp]
    let compare = compare
    let hash = Hashtbl.hash
    let module_name = Some "Veri_stat"
    let version = "0.1"

    let pp_misexecuted fmt = function
      | [] -> ()
      | mis -> 
        Format.fprintf fmt "misexecuted \n";
        print_table fmt 
          [ "instruction", fst;
            "failed", (fun (_, (_,er)) -> Printf.sprintf "%d" er);
            "successful", (fun (_, (ok,_)) -> Printf.sprintf "%d" ok); ] 
          mis

    let pp_mislifted fmt names = 
      let open Textutils.Std in
      let open Ascii_table in
      let max_row_len = 10 in
      let max_col_cnt = 5 in
      match names with 
      | [] -> ()
      | names when List.length names <= max_row_len ->
        let names' = "mislifted:" :: names in
        List.iter ~f:(Format.fprintf fmt "%s ") names';
        Format.print_newline ()
      | names ->
        let rows, last, _ = List.fold ~init:([], [], 0)
            ~f:(fun (acc, row, i) name ->
                if i < max_col_cnt then acc, name :: row, i + 1
                else row :: acc, name :: [], 1) names in
        let last = last @ Array.to_list 
                 (Array.create ~len:(max_col_cnt - List.length last) "---" ) in
        let rows = List.rev (last :: rows) in
        let make_col i = 
          Column.create "mislifted" (fun row -> List.nth_exn row i) in
        let cols = [
          make_col 0; make_col 1; make_col 2; make_col 3; make_col 4] in
        to_string ~bars:`Ascii ~display:Display.short_box cols rows |>
        Format.fprintf fmt "%s" 
        
    let pp fmt t = 
      let misexec = 
        List.filter ~f:(fun (_,(_,er)) -> er <> 0) (Map.to_alist t.calls) in
      let mislift = Names.mislifted t in
      Format.fprintf fmt "%a\n%a\n"
        pp_misexecuted misexec pp_mislifted mislift
  end)

module Summary = struct

  type t = {
    stats : stat String.Map.t;
    full  : stat;
  } [@@deriving bin_io, compare, sexp]

  type p = {
    name: string;
    rel : float;
    abs : int;
  } [@@deriving bin_io, sexp, compare]

  let empty  = { stats = String.Map.empty; full = create () }
  let add t name stat = 
    let stats = Map.add t.stats ~key:name ~data:stat in
    let full = merge t.full stat in
    { stats; full; }

  let stats t = Map.to_alist t.stats
  let full t = t.full

  let of_stats {full} =
    let make name abs rel = {name; abs; rel;} in
    if Abs.total full = 0 then []
    else
      let s = full in
      [ make "overloaded"  (Abs.overloaded s)  (Rel.overloaded s);
        make "undisasmed"  (Abs.undisasmed s)  (Rel.undisasmed s);
        make "misexecuted" (Abs.misexecuted s) (Rel.misexecuted s);
        make "mislifted"   (Abs.mislifted s)   (Rel.mislifted s);
        make "damaged"     (Abs.damaged s)     (Rel.damaged s);
        make "successed"   (Abs.successed s)   (Rel.successed s);]

  include Regular.Make(struct
      type nonrec t = t [@@deriving bin_io, compare, sexp]
      let compare = compare
      let hash = Hashtbl.hash
      let module_name = Some "Veri_stat.Summary"
      let version = "0.1"

      let pp fmt t = match of_stats t with
        | [] -> Format.fprintf fmt "summary is unavailable\n"
        | ps ->
          print_table fmt 
            ["", (fun x -> x.name);
             "rel", (fun x -> Printf.sprintf "%.2f%%" x.rel);
             "abs",  (fun x -> Printf.sprintf "%d" x.abs);]
            ps
    end)
end

type summary = Summary.t [@@deriving bin_io, sexp]

include R
