(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)
signature TYPE_STRUCTS =
   sig
      structure Record: RECORD
      structure Tycon: TYCON
      structure Tyvar: TYVAR
   end

signature TYPE = 
   sig
      include TYPE_STRUCTS
      include TYPE_OPS
	 where type intSize = Tycon.IntSize.t
	 where type realSize = Tycon.RealSize.t
	 where type tycon = Tycon.t
	 where type wordSize = Tycon.WordSize.t
	    
      datatype t' =
	 Con of Tycon.t * t' vector
       | Record of t' Record.t
       | Var of Tyvar.t
      sharing type t = t'

      val equals: t * t -> bool
      val hom: {ty: t,
		var: Tyvar.t -> 'a,
		con: Tycon.t * 'a vector -> 'a} -> 'a
      val layout: t -> Layout.t
      val record: t Record.t -> t
      (* substitute(t, [(a1, t1), ..., (an, tn)]) performs simultaneous
       * substitution of the ti for ai in t.
       *)
      val substitute: t * (Tyvar.t * t) vector -> t
      (* tyvars returns a list (without duplicates) of all the type variables
       * in a type.
       *)
      val tyvars: t -> Tyvar.t list
      val var: Tyvar.t -> t
   end

