open Core_kernel

let m = 3

let capacity = 1

let rate = m - capacity

type 'f sponge_state =
  | Absorbing of
      { next_index: 'f Snarky.Boolean.t
      ; xs: ('f Snarky.Boolean.t * 'f) list }
  | Squeezed of int

type 'f t =
  { mutable state: 'f array
  ; params: 'f Sponge.Params.t
  ; mutable sponge_state: 'f sponge_state }

module Make (Impl : Snarky.Snark_intf.Run with type prover_state = unit) =
struct
  module Inputs = Sponge_inputs.Make (Impl)
  module P = Sponge.Poseidon (Inputs)
  open P
  open Impl

  type nonrec t = Field.t t

  let state {state; _} = Array.copy state

  let copy {state; params; sponge_state} =
    {state= Array.copy state; params; sponge_state}

  let initial_state = Array.init m ~f:(fun _ -> Field.zero)

  let of_sponge {Sponge.state; params; sponge_state} =
    let sponge_state =
      match sponge_state with
      | Squeezed n ->
          Squeezed n
      | Absorbed n ->
          let next_index =
            match n with
            | 0 ->
                Boolean.false_
            | 1 ->
                Boolean.true_
            | _ ->
                assert false
          in
          Absorbing {next_index; xs= []}
    in
    {sponge_state; state= Array.copy state; params}

  let create ?(init = initial_state) params =
    { params
    ; state= Array.copy init
    ; sponge_state= Absorbing {next_index= Boolean.false_; xs= []} }

  let () = assert (rate = 2)

  let add_in a i x =
    let i_equals_0 = Boolean.not i in
    let i_equals_1 = i in
    (* 
      a.(0) <- a.(0) + i_equals_0 * x
      a.(1) <- a.(1) + i_equals_1 * x *)
    List.iteri [i_equals_0; i_equals_1] ~f:(fun j i_equals_j ->
        let a_j' =
          exists Field.typ
            ~compute:
              As_prover.(
                fun () ->
                  let a_j = read Field.typ a.(j) in
                  if read Boolean.typ i_equals_j then
                    Field.Constant.(a_j + read Field.typ x)
                  else a_j)
        in
        assert_r1cs x (i_equals_j :> Field.t) Field.(a_j' - a.(j)) ;
        a.(j) <- a_j' )

  let consume ~params ~start_pos input state =
    assert (Array.length state = m) ;
    let n = Array.length input in
    let pos = ref start_pos in
    let cond_permute permute =
      let permuted = P.block_cipher params (Array.copy state) in
      for i = 0 to m - 1 do
        state.(i) <- Field.if_ permute ~then_:permuted.(i) ~else_:state.(i)
      done
    in
    let pairs = n / 2 in
    let remaining = n - (2 * pairs) in
    for i = 0 to pairs - 1 do
      (* Semantically, we want to do this.
         match b, b' with
         | 1, 1 ->
          if p = 0
          then state := perm {state with .0 += x, .1 += y }
          else state := {perm {state with .1 += x} with .0 += y}
         | 1, 0 ->
          if p = 0
          then state := {state with .0 += x}
          else state := perm {state with .1 += x}
         | 0, 1 ->
          if p = 0
          then state := {state with .0 += y }
          else state := perm {state with .1 += y}
         | 0, 0 ->
          state
      *)
      let b, x = input.(2 * i) in
      let b', y = input.((2 * i) + 1) in
      let p = !pos in
      let p' = Boolean.( lxor ) p b in
      pos := Boolean.( lxor ) p' b' ;
      let y = Field.(y * (b' :> t)) in
      let add_in_y_after_perm =
        (* post
          add in 
          (1, 1, 1)

          do not add in
          (1, 1, 0)
          (0, 1, 0)
          (0, 1, 1)

          (1, 0, 0)
          (1, 0, 1)
          (0, 0, 0)
          (0, 0, 1)
        *)
        (* Only one case where we add in y after the permutation is applied *)
        Boolean.all [b; b'; p]
      in
      let add_in_y_before_perm = Boolean.not add_in_y_after_perm in
      add_in state p Field.(x * (b :> t)) ;
      add_in state p' Field.(y * (add_in_y_before_perm :> t)) ;
      let permute =
        (* (b, b', p)
           true:
           (0, 1, 1)
           (1, 0, 1)
           (1, 1, 0)
           (1, 1, 1)

          false:
           (0, 0, 0)
           (0, 0, 1)
           (0, 1, 0)
           (1, 0, 0)
        *)
        (* (b && b') || (p && (b || b')) *)
        Boolean.(any [all [b; b']; all [p; b || b']])
      in
      cond_permute permute ;
      add_in state p' Field.(y * (add_in_y_after_perm :> t))
    done ;
    let empty_imput =
      Boolean.not (Boolean.Array.any (Array.map input ~f:fst))
    in
    let should_permute =
      match remaining with
      | 0 ->
          Boolean.(empty_imput || !pos)
      | 1 ->
          let b, x = input.(n - 1) in
          let p = !pos in
          pos := Boolean.( lxor ) p b ;
          add_in state p Field.(x * (b :> t)) ;
          Boolean.any [p; b; empty_imput]
      | _ ->
          assert false
    in
    cond_permute should_permute

  let absorb (t : t) x =
    match t.sponge_state with
    | Absorbing {next_index; xs} ->
        t.sponge_state <- Absorbing {next_index; xs= x :: xs}
    | Squeezed _ ->
        t.sponge_state <- Absorbing {next_index= Boolean.false_; xs= [x]}

  let squeeze (t : t) =
    match t.sponge_state with
    | Squeezed n ->
        if n = rate then (
          t.state <- block_cipher t.params t.state ;
          t.sponge_state <- Squeezed 1 ;
          t.state.(0) )
        else (
          t.sponge_state <- Squeezed (n + 1) ;
          t.state.(n) )
    | Absorbing {next_index; xs} ->
        consume ~start_pos:next_index ~params:t.params (Array.of_list_rev xs)
          t.state ;
        t.sponge_state <- Squeezed 1 ;
        t.state.(0)

  let%test_module "opt_sponge" =
    ( module struct
      module S = Sponge.Make_sponge (P)

      let%test_unit "correctness" =
        let gen =
          let open Quickcheck.Generator.Let_syntax in
          let%bind n = Quickcheck.Generator.small_positive_int in
          let%map xs = List.gen_with_length n Field.Constant.gen
          and bs = List.gen_with_length n Bool.quickcheck_generator in
          List.zip_exn bs xs
        in
        Quickcheck.test gen ~trials:5 ~f:(fun ps ->
            let filtered =
              List.filter_map ps ~f:(fun (b, x) -> if b then Some x else None)
            in
            let params : _ Sponge.Params.t =
              let a () =
                Array.init 3 ~f:(fun _ -> Field.(constant (Constant.random ())))
              in
              { mds= Array.init 3 ~f:(fun _ -> a ())
              ; round_constants= Array.init 40 ~f:(fun _ -> a ()) }
            in
            let filtered_res =
              let n = List.length filtered in
              Impl.Internal_Basic.Test.checked_to_unchecked
                (Typ.list ~length:n Field.typ)
                Field.typ
                (fun xs ->
                  make_checked (fun () ->
                      let s = S.create params in
                      List.iter xs ~f:(S.absorb s) ;
                      S.squeeze s ) )
                filtered
            in
            let opt_res =
              let n = List.length ps in
              Impl.Internal_Basic.Test.checked_to_unchecked
                (Typ.list ~length:n (Typ.tuple2 Boolean.typ Field.typ))
                Field.typ
                (fun xs ->
                  make_checked (fun () ->
                      let s = create params in
                      List.iter xs ~f:(absorb s) ;
                      squeeze s ) )
                ps
            in
            if not (Field.Constant.equal filtered_res opt_res) then
              failwithf
                !"hash(%{sexp:Field.Constant.t list}) = \
                  %{sexp:Field.Constant.t}\n\
                  hash(%{sexp:(bool * Field.Constant.t) list}) = \
                  %{sexp:Field.Constant.t}"
                filtered filtered_res ps opt_res () )
    end )
end
