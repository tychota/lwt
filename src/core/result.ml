(* TODO This is a temporary hack; we have to depend on package result instead,
   if that's available in NPM somehow. *)

type ('a, 'b) result =
  | Ok of 'a
  | Error of 'b
