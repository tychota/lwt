(* OCaml promise library
 * http://www.ocsigen.org/lwt
 * Copyright (C) 2005-2008 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *               2009-2012 Jérémie Dimino
 *               2017      Anton Bachin
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)



let not_implemented api =
  Printf.ksprintf failwith "'%s' not implemented" api



type 'a t = 'a Js.Promise.t

type 'a u = {
  fulfill : ('a -> unit [@bs]);
  reject : (exn -> unit [@bs]);
}

let task () =
  let r = ref None in

  let p =
    Js.Promise.make (fun ~resolve ~reject ->
      r := Some {
        fulfill = resolve;
        reject = reject
      });
  in

  let r =
    match !r with
    | Some r -> r
    | None -> assert false
  in

  (p, r)



let wakeup_later r v =
  r.fulfill v [@bs]

let wakeup_later_exn r exn =
  r.reject exn [@bs]

let wakeup_later_result r result =
  match result with
  | Result.Ok v -> wakeup_later r v
  | Result.Error exn -> wakeup_later_exn r exn

let wakeup = wakeup_later
let wakeup_exn = wakeup_later_exn
let wakeup_result = wakeup_later_result



let return v =
  Js.Promise.resolve v

let return_unit =
  return ()

let fail exn =
  Js.Promise.reject exn



let async_exception_hook =
  ref (fun _exn -> not_implemented "async_exception_hook")



let bind p1 f =
  Js.Promise.then_ f p1

let map f p1 =
  bind p1 (fun v -> return (f v))

let catch f (h : exn -> _ t) =
  let p1 =
    try f ()
    with exn -> fail exn
  in

  let (h : Js.Promise.error -> _ t) = Obj.magic h in

  Js.Promise.catch h p1

let on_success p f =
  bind p (fun v ->
    (try f v
    with exn -> !async_exception_hook exn);
    return_unit)
  |> ignore

let on_failure p f =
  catch (fun () -> p) (fun exn ->
    (try f exn
    with exn' -> !async_exception_hook exn');
    return_unit)
  |> ignore

let on_termination p f =
  on_success p (fun _v -> f ());
  on_failure p (fun _exn -> f ())

let on_any p f g =
  on_success p f;
  on_failure p g

(* TODO It should be possible to implement this more intelligently using the
   two-function form of Promise.then. *)
let try_bind f f' h =
  let p1 =
    try f ()
    with exn1 -> fail exn1
  in

  let p3, r3 = task () in

  on_success p1 (fun v1 ->
    let p2 =
      try f' v1
      with exn2 -> fail exn2
    in
    on_success p2 (fun v2 -> wakeup_later r3 v2);
    on_failure p2 (fun exn2 -> wakeup_later_exn r3 exn2));

  on_failure p1 (fun exn1 ->
    let p2 =
      try h exn1
      with exn2 -> fail exn2
    in
    on_success p2 (fun v2 -> wakeup_later r3 v2);
    on_failure p2 (fun exn2 -> wakeup_later_exn r3 exn2));

  p3

let finalize f f' =
  try_bind f
    (fun v ->
      bind
        (f' ())
        (fun () -> return v))
    (fun exn ->
      bind
        (f' ())
        (fun () -> fail exn))



let async f =
  catch f (fun exn ->
    !async_exception_hook exn;
    return_unit)
  |> ignore



let join ps =
  ps |> Array.of_list |> Js.Promise.all |> map ignore

let pick ps =
  ps |> Array.of_list |> Js.Promise.race

let choose ps =
  pick ps

let npick _ps =
  not_implemented "npick"

let nchoose _ps =
  not_implemented "nchoose"

let nchoose_split _ps =
  not_implemented "nchoose_split"



exception Canceled

let cancel _p =
  not_implemented "cancel"

let on_cancel _p _f =
  ()

let protected _p =
  not_implemented "protected"

let no_cancel _p =
  not_implemented "no_cancel"

let wait () =
  task ()



module Infix =
struct
  let (>>=) = bind

  let (>|=) p1 f = map f p1

  let (<?>) p1 p2 = choose [p1; p2]

  let (<&>) p1 p2 = join [p1; p2]

  let (=<<) f p1 = bind p1 f

  let (=|<) = map
end



let return_none =
  return None

let return_nil =
  return []

let return_true =
  return true

let return_false =
  return false



type +'a result = ('a, exn) Result.result

let of_result result =
  match result with
  | Result.Ok v -> return v
  | Result.Error e -> fail e



type 'a state =
  | Return of 'a
  | Fail of exn
  | Sleep

(* TODO Explain this hack. *)
(* TODO Inspired by https://makandracards.com/makandra/46681. *)
(* TODO Depends on the implementation of race returning one of the resolved
   promises directly. Use of this function should be discouraged, except in
   testing, where it is kind of indispensable. *)
let state p =
  (* The purpose of this promise is to force resolution of the promise resulting
     from [race], to avoid a memory leak. See below. *)
  let dummy_pending_promise, resolve_dummy_promise = task () in

  let state = ref Sleep in

  let race_promise = Js.Promise.race [|p; Obj.magic dummy_pending_promise|] in

  bind
    race_promise
    (fun v ->
      state := Return v;
      return_unit)
  |> ignore;

  catch
    (fun () ->
      race_promise)
    (fun exn ->
      state := Fail exn;
      return_unit)
  |> ignore;

  let state = !state in

  wakeup_later resolve_dummy_promise ();

  state

(* TODO Clarify this comment. *)
(* Based on the understanding that .then callbacks are serviced in FIFO order,
   so scheduling .then callbacks on an already-resolved promise will put them in
   the queue immediately, and a cleanup callback will be put in the queue
   afterward; on the other hand, if the promise is not already resolved, the
   cleanup callback will go in the queue first. See

     http://www.ecma-international.org/ecma-262/6.0/#sec-jobs-and-job-queues

   This also assumes that [race] returns a promise that is resolved immediately,
   if one of the promises is already resolved. *)
let debug_get_state p =
  (* The purpose of this promise is to force resolution of the promise resulting
     from [race], to avoid a memory leak. See below. *)
  let dummy_pending_promise, resolve_dummy_promise = task () in

  let (state_promise, state_resolver) = task () in
  let state_resolved = ref false in
  let resolve_state state =
    if not @@ !state_resolved then begin
      wakeup_later state_resolver state;
      state_resolved := true
    end
  in

  let race_promise = Js.Promise.race [|p; Obj.magic dummy_pending_promise|] in

  bind
    race_promise
    (fun v ->
      resolve_state (Return v);
      return_unit)
  |> ignore;

  catch
    (fun () ->
      race_promise)
    (fun exn ->
      resolve_state (Fail exn);
      return_unit)
  |> ignore;

  (* TODO This is only suitable for the controlled environment of tests, not for
     production. *)
  let rec terminate_state_poll_later ticks_remaining =
    match ticks_remaining with
    | 0 ->
      resolve_state Sleep;
      wakeup_later resolve_dummy_promise ();
      return_unit
    | _ ->
      bind return_unit (fun () ->
      terminate_state_poll_later (ticks_remaining - 1))
  in
  (* TODO the tick count is currently forced by the implementation of finalize,
     try to decrease it is finalize is better implemented. *)
  terminate_state_poll_later 10
  |> ignore;

  state_promise

let debug_state_is state p =
  let open Infix in
  debug_get_state p >|= (=) state



type 'a key

let new_key () =
  not_implemented "new_key"

let get _key =
  not_implemented "get_key"

let with_value _key _value _f =
  not_implemented "with_value"



let make_value v =
  Result.Ok v

let make_error exn =
  Result.Error exn

let waiter_of_wakener _r =
  not_implemented "waiter_of_wakener"



let add_task_r sequence =
  let p, r = task () in
  Lwt_sequence.add_r r sequence |> ignore;
  p

let add_task_l sequence =
  let p, r = task () in
  Lwt_sequence.add_l r sequence |> ignore;
  p



let paused : ((unit u) list) ref = ref []
let paused_count = ref 0

let pause_notifier = ref ignore

let pause () =
  let p, r = task () in
  paused := r::!paused;
  paused_count := !paused_count + 1;
  !pause_notifier !paused_count;
  p

let wakeup_paused () =
  match !paused with
  | [] ->
    paused_count := 0
  | _ ->
    let current_paused_promise_resolvers = !paused in
    paused := [];
    paused_count := 0;
    List.iter (fun r -> wakeup_later r ()) current_paused_promise_resolvers

let paused_count () =
  !paused_count

let register_pause_notifier f =
  pause_notifier := f



let wrap f = try return (f ()) with exn -> fail exn

let wrap1 f x1 =
  try return (f x1)
  with exn -> fail exn

let wrap2 f x1 x2 =
  try return (f x1 x2)
  with exn -> fail exn

let wrap3 f x1 x2 x3 =
  try return (f x1 x2 x3)
  with exn -> fail exn

let wrap4 f x1 x2 x3 x4 =
  try return (f x1 x2 x3 x4)
  with exn -> fail exn

let wrap5 f x1 x2 x3 x4 x5 =
  try return (f x1 x2 x3 x4 x5)
  with exn -> fail exn

let wrap6 f x1 x2 x3 x4 x5 x6 =
  try return (f x1 x2 x3 x4 x5 x6)
  with exn -> fail exn

let wrap7 f x1 x2 x3 x4 x5 x6 x7 =
  try return (f x1 x2 x3 x4 x5 x6 x7)
  with exn -> fail exn



let return_some v =
  return (Some v)

let return_ok v =
  return (Result.Ok v)

let return_error e =
  return (Result.Error e)



let fail_with message =
  fail (Failure message)

let fail_invalid_arg message =
  fail (Invalid_argument message)



let (>>=) p1 f =
  Infix.(p1 >>= f)

let (>|=) p1 f =
  Infix.(p1 >|= f)

let (<?>) p1 p2 =
  Infix.(p1 <?> p2)

let (<&>) p1 p2 =
  Infix.(p1 <&> p2)

let (=<<) f p1 =
  Infix.(f =<< p1)

let (=|<) f p1 =
  Infix.(f =|< p1)



let is_sleeping _p =
  not_implemented "is_sleeping"

let ignore_result _p =
  not_implemented "ignore_result"



let poll _p =
  not_implemented "poll"

let apply f v =
  try f v
  with exn -> fail exn



let backtrace_bind _add_loc p1 f =
  bind p1 f

let backtrace_catch _add_loc f h =
  catch f h

let backtrace_finalize _add_loc f f' =
  finalize f f'

let backtrace_try_bind _add_loc f f' h =
  try_bind f f' h



let abandon_wakeups () =
  not_implemented "abandon_wakeups"



let debug_underlying_implementation =
  `JS
