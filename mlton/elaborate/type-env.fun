(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)
functor TypeEnv (S: TYPE_ENV_STRUCTS): TYPE_ENV =
struct

open S

structure AdmitsEquality = Tycon.AdmitsEquality
structure Field = Record.Field
structure Srecord = SortedRecord
structure Set = DisjointSet

(*
 * Keep a clock so that when we need to generalize a type we can tell which
 * unknowns were created in the expression being generalized.
 *
 * Keep track of all unknowns and the time allocated. 
 *
 * Unify should always keep the older unknown.
 *
 * If they are unknowns since the clock, they may be generalized.
 *
 * For type variables, keep track of the time that they need to be generalized
 * at.  If they are ever unified with an unknown of an earlier time, then
 * they can't be generalized.
 *)
structure Time:>
   sig
      type t

      val <= : t * t -> bool
      val equals: t * t -> bool
      val min: t * t -> t
      val layout: t -> Layout.t
      val now: unit -> t
      val tick: unit -> t
   end =
   struct
      type t = int

      val equals = op =
	 
      val min = Int.min

      val op <= = Int.<=

      val layout = Int.layout

      val clock: t ref = ref 0

      fun now () = !clock

      fun tick () = (clock := 1 + !clock
		     ; !clock)
   end

structure Lay =
   struct
      type t = Layout.t * {isChar: bool, needsParen: bool}

      fun simple (l: Layout.t): t =
	 (l, {isChar = false, needsParen = false})
   end
      
structure UnifyResult =
   struct
      datatype t =
	 NotUnifiable of Lay.t * Lay.t
       | Unified

      val layout =
	 let
	    open Layout
	 in
	    fn NotUnifiable _ => str "NotUnifiable"
	     | Unified => str "Unified"
	 end
   end

val {get = tyconAdmitsEquality: Tycon.t -> AdmitsEquality.t ref, ...} =
   Property.get (Tycon.plist,
		 Property.initFun (fn _ => ref AdmitsEquality.Sometimes))

val _ =
   List.foreach (Tycon.prims, fn (c, _, a) => tyconAdmitsEquality c := a)

structure Equality:>
   sig
      type t

      val and2: t * t -> t
      val andd: t vector -> t
      val applyTycon: Tycon.t * t vector -> t
      val falsee: t
      val fromBool: bool -> t
      val toBool: t -> bool
      val toBoolOpt: t -> bool option
      val truee: t
      val unify: t * t -> UnifyResult.t
      val unknown: unit -> t
   end =
   struct
      datatype maybe =
	 Known of bool
       | Unknown of {whenKnown: (bool -> bool) list ref}
      datatype t =
	 False
       | Maybe of maybe ref
       | True

      fun unknown () = Maybe (ref (Unknown {whenKnown = ref []}))

      fun set (e: t, b: bool): bool =
	 case e of
	    False => b = false
	  | Maybe r =>
	       (case !r of
		   Known b' => b = b'
		 | Unknown {whenKnown} =>
		      (r := Known b; List.forall (!whenKnown, fn f => f b)))
	  | True => b = true

      fun when (e: t, f: bool -> bool): bool =
	 case e of
	    False => f false
	  | Maybe r =>
	       (case !r of
		   Known b => f b
		 | Unknown {whenKnown} => (List.push (whenKnown, f); true))
	  | True => f true

      fun unify (e: t, e': t): bool =
	 when (e, fn b => set (e', b))
	 andalso when (e', fn b => set (e, b))

      fun and2 (e, e') =
	 case (e, e') of
	    (False, _) => False
	  | (_, False) => False
	  | (True, _) => e'
	  | (_, True) => e
	  | (Maybe r, Maybe r') =>
	       (case (!r, !r') of
		   (Known false, _) => False
		 | (_, Known false) => False
		 | (Known true, _) => e'
		 | (_, Known true) => e
		 | (Unknown _, Unknown _) =>
		      let
			 val e'' = unknown ()
			 val _ =
			    when
			    (e'', fn b =>
			     if b
				then set (e, true) andalso set (e', true)
			     else
				let
				   fun dep (e, e') =
				      when (e, fn b =>
					    not b orelse set (e', false))
				in
				   dep (e, e') andalso dep (e', e)
				end)
			 fun dep (e, e') =
			    when (e, fn b =>
				  if b then unify (e', e'')
				  else set (e'', false))
			 val _ = dep (e, e')
			 val _ = dep (e', e)
		      in
			 e''
		      end)
	    
      val falsee = False
      val truee = True

      val fromBool = fn false => False | true => True

      fun toBoolOpt (e: t): bool option =
	 case e of
	    False => SOME false
	  | Maybe r =>
	       (case !r of
		   Known b => SOME b
		 | Unknown _ => NONE)
	  | True => SOME true

      fun toBool e =
	 case toBoolOpt e of
	    NONE => Error.bug "Equality.toBool"
	  | SOME b => b

      fun andd (es: t vector): t = Vector.fold (es, truee, and2)

      val applyTycon: Tycon.t * t vector -> t =
	 fn (c, es) =>
	 let
	    datatype z = datatype AdmitsEquality.t
	 in
	    case !(tyconAdmitsEquality c) of
	       Always => truee
	     | Sometimes => andd es
	     | Never => falsee
	 end
	 
      val unify: t * t -> UnifyResult.t =
	 fn (e, e') =>
	 if unify (e, e')
	    then UnifyResult.Unified
	 else
	    let
	       fun lay e =
		  Lay.simple
		  (Layout.str (if toBool e
				  then "<equality>"
			       else "<non-equality>"))
	    in
	       UnifyResult.NotUnifiable (lay e, lay e')
	    end
   end
   
structure Unknown =
   struct
      datatype t = T of {canGeneralize: bool,
			 id: int,
			 time: Time.t ref}

      local
	 fun make f (T r) = f r
      in
	 val time = ! o (make #time)
      end

      fun layout (T {canGeneralize, id, time, ...}) =
	 let
	    open Layout
	 in
	    seq [str "Unknown ",
		 record [("canGeneralize", Bool.layout canGeneralize),
			 ("id", Int.layout id),
			 ("time", Time.layout (!time))]]
	 end

      fun minTime (u as T {time, ...}, t) =
	 if Time.<= (!time, t)
	    then ()
	 else time := t

      fun layoutPretty (T {id, ...}) =
	 let
	    open Layout
	 in
	    seq [str "'a", Int.layout id]
	 end

      val toString = Layout.toString o layoutPretty
      
      local
	 val r: int ref = ref 0
      in
	 fun newId () = (Int.inc r; !r)
      end

      fun new {canGeneralize} =
	 T {canGeneralize = canGeneralize,
	    id = newId (),
	    time = ref (Time.now ())}

      fun join (T r, T r'): t =
	 T {canGeneralize = #canGeneralize r andalso #canGeneralize r',
	    id = newId (),
	    time = ref (Time.min (! (#time r), ! (#time r')))}
   end

(* Flexible record spine, i.e. a possibly extensible list of fields. *)
structure Spine:
   sig
      type t

      val canAddFields: t -> bool
      val empty: unit -> t
      val equals: t * t -> bool
      val fields: t -> Field.t list
      (* ensureField checks if field is there.  If it is not, then ensureField
       * will add it unless no more fields are allowed in the spine.
       * It returns true iff it succeeds.
       *)
      val ensureField: t * Field.t -> bool
      val foldOverNew: t * (Field.t * 'a) list * 'b * (Field.t * 'b -> 'b) -> 'b
      val layout: t -> Layout.t
      val new: Field.t list -> t
      val noMoreFields: t -> unit
      (* Unify returns the fields that are in each spine but not in the other.
       *)
      val unify: t * t -> unit
   end =
   struct
      datatype t = T of {fields: Field.t list ref,
			 more: bool ref} Set.t

      fun new fields = T (Set.singleton {fields = ref fields,
					 more = ref true})

      fun equals (T s, T s') = Set.equals (s, s')

      fun empty () = new []

      fun layout (T s) =
	 let
	    val {fields, more} = Set.value s
	 in
	    Layout.record [("fields", List.layout Field.layout (!fields)),
			   ("more", Bool.layout (!more))]
	 end

      fun canAddFields (T s) = ! (#more (Set.value s))
      fun fields (T s) = ! (#fields (Set.value s))

      fun ensureFieldValue ({fields, more}, f) =
	 List.contains (!fields, f, Field.equals)
	 orelse (!more andalso (List.push (fields, f); true))

      fun ensureField (T s, f) = ensureFieldValue (Set.value s, f)

      fun noMoreFields (T s) = #more (Set.value s) := false

      fun unify (T s, T s') =
	 let
	    val {fields = fs, more = m} = Set.value s
	    val {more = m', ...} = Set.value s'
	    val _ = Set.union (s, s')
	    val _ = Set.setValue (s, {fields = fs, more = ref (!m andalso !m')})
	 in
	    ()
	 end

      fun foldOverNew (spine: t, fs, ac, g) =
	 List.fold
	 (fields spine, ac, fn (f, ac) =>
	  if List.exists (fs, fn (f', _) => Field.equals (f, f'))
	     then ac
	  else g (f, ac))
   end

val {get = tyvarTime: Tyvar.t -> Time.t ref, ...} =
   Property.get (Tyvar.plist, Property.initFun (fn _ => ref (Time.now ())))

local
   type z = Layout.t * {isChar: bool, needsParen: bool}
   open Layout
in
   fun simple (l: Layout.t): z =
      (l, {isChar = false, needsParen = false})
   val dontCare: z = simple (str "_")
   fun bracket l = seq [str "[", l, str "]"]
   fun layoutRecord (ds: (Field.t * bool * z) list, flexible: bool) =
      simple (case ds of
		 [] => str "{...}"
	       | _ => 
		    seq [str "{",
			 mayAlign
			 (separateRight
			  (List.map
			   (QuickSort.sortList (ds, fn ((f, _, _), (f', _, _)) =>
						Field.<= (f, f')),
			    fn (f, b, (l, _)) =>
			    let
			       val f = Field.layout f
			       val f = if b then bracket f else f
			    in
			       seq [f, str ": ", l]
			    end),
			   ",")),
			 str (if flexible
				 then ", ...}"
			      else "}")])
   fun layoutTuple (zs: z vector): z =
      Tycon.layoutApp (Tycon.tuple, zs)
end

structure Type =
   struct
      (* Tuples of length <> 1 are always represented as records.
       * There will never be tuples of length one.
       *)
      datatype t = T of {equality: Equality.t,
			 plist: PropertyList.t,
			 ty: ty} Set.t
      and ty =
	 Con of Tycon.t * t vector
	| FlexRecord of {fields: fields,
			 spine: Spine.t,
			 time: Time.t ref}
	(* GenFlexRecord only appears in type schemes.
	 * It will never be unified.
	 * The fields that are filled in after generalization are stored in
	 * extra.
	 *)
	| GenFlexRecord of genFlexRecord
	| Int (* an unresolved int type *)
	| Real (* an unresolved real type *)
	| Record of t Srecord.t
	| Unknown of Unknown.t
	| Var of Tyvar.t
	| Word (* an unresolved word type *)
      withtype fields = (Field.t * t) list
      and genFlexRecord =
	 {extra: unit -> {field: Field.t,
			  tyvar: Tyvar.t} list,
	  fields: (Field.t * t) list,
	  spine: Spine.t}
 
      val freeFlexes: t list ref = ref []
      val freeUnknowns: t list ref = ref []

      local
	 fun make f (T s) = f (Set.value s)
      in
	 val equality = make #equality
	 val plist: t -> PropertyList.t = make #plist
	 val toType: t -> ty = make #ty
      end

      local
	 open Layout
      in
	 fun layoutFields fs =
	    List.layout (Layout.tuple2 (Field.layout, layout)) fs
	 and layout ty =
	    case toType ty of
	       Con (c, ts) =>
		  paren (align [seq [str "Con ", Tycon.layout c],
				Vector.layout layout ts])
	     | FlexRecord {fields, spine, time} =>
		  seq [str "Flex ",
		       record [("fields", layoutFields fields),
			       ("spine", Spine.layout spine),
			       ("time", Time.layout (!time))]]
	     | GenFlexRecord {fields, spine, ...} =>
		  seq [str "GenFlex ",
		       record [("fields", layoutFields fields),
			       ("spine", Spine.layout spine)]]
	     | Int => str "Int"
	     | Real => str "Real"
	     | Record r => Srecord.layout {record = r,
					   separator = ": ",
					   extra = "",
					   layoutTuple = Vector.layout layout,
					   layoutElt = layout}
	     | Unknown u => Unknown.layout u
	     | Var a => paren (seq [str "Var ", Tyvar.layout a])
	     | Word => str "Word"
      end

      val toString = Layout.toString o layout

      val admitsEquality = Equality.toBool o equality

      val admitsEquality =
	 Trace.trace ("admitsEquality", layout, Bool.layout) admitsEquality

      fun union (T s, T s') = Set.union (s, s')

      fun set (T s, v) = Set.setValue (s, v)

      val {get = opaqueTyconExpansion: Tycon.t -> (t vector -> t) option,
	   set = setOpaqueTyconExpansion, ...} =
	 Property.getSet (Tycon.plist, Property.initConst NONE)

      val opaqueTyconExpansion =
	 Trace.trace ("opaqueTyconExpansion",
		      Tycon.layout,
		      Layout.ignore)
	 opaqueTyconExpansion

      datatype expandOpaque =
	 Always
	| Never
	| Sometimes of Tycon.t -> bool

      fun makeHom {con, expandOpaque, flexRecord, genFlexRecord, int, real,
		   record, recursive, unknown, var, word} =
	 let
	    datatype status = Processing | Seen | Unseen
	    val {destroy = destroyStatus, get = status, ...} =
	       Property.destGet (plist, Property.initFun (fn _ => ref Unseen))
	    val {get, destroy = destroyProp} =
	       Property.destGet
	       (plist,
		Property.initRec
		(fn (t, get) =>
		 let
		    val r = status t
		 in
		    case !r of
		       Seen => Error.bug "impossible"
		     | Processing => recursive t
		     | Unseen =>
			  let
			     val _ = r := Processing
			     fun loopFields fields =
				List.revMap (fields, fn (f, t) => (f, get t))
			     val res = 
				case toType t of
				   Con (c, ts) =>
				      let
					 fun no () =
					    con (t, c, Vector.map (ts, get))
					 fun yes () =
					    (case opaqueTyconExpansion c of
						NONE => no ()
					      | SOME f => get (f ts))
				      in
					 case expandOpaque of
					    Always => yes ()
					  | Never => no ()
					  | Sometimes f =>
					       if f c then yes () else no ()
				      end
				 | Int => int t
				 | FlexRecord {fields, spine, time} =>
				      flexRecord (t, {fields = loopFields fields,
						      spine = spine,
						      time = time})
				 | GenFlexRecord {extra, fields, spine} =>
				      genFlexRecord
				      (t, {extra = extra,
					   fields = loopFields fields,
					   spine = spine})
				 | Real => real t
				 | Record r => record (t, Srecord.map (r, get))
				 | Unknown u => unknown (t, u)
				 | Var a => var (t, a)
				 | Word => word t
			     val _ = r := Seen
			  in
			     res
			  end
		 end))
	    fun destroy () =
	       (destroyStatus ()
		; destroyProp ())
	 in
	    {hom = get, destroy = destroy}
	 end

      fun hom (ty, z) =
	 let
	    val {hom, destroy} = makeHom z
	    val res = hom ty
	    val _ = destroy ()
	 in
	    res
	 end

      fun makeLayoutPretty (): {destroy: unit -> unit,
				lay: t -> Layout.t * {isChar: bool,
						      needsParen: bool}} =
	 let
	    val str = Layout.str
	    fun maybeParen (b, t) = if b then Layout.paren t else t
	    fun con (_, c, ts) = Tycon.layoutApp (c, ts)
	    fun int _ = simple (str "int")
	    fun flexRecord (_, {fields, spine, time}) =
	       layoutRecord
	       (List.fold
		(fields,
		 Spine.foldOverNew (spine, fields, [], fn (f, ac) =>
				    (f, false, simple (str "unit"))
				    :: ac),
		 fn ((f, t), ac) => (f, false, t) :: ac),
		Spine.canAddFields spine)
	    fun genFlexRecord (_, {extra, fields, spine}) =
	       layoutRecord
	       (List.fold
		(fields,
		 List.revMap (extra (), fn {field, tyvar} =>
			      (field, false, simple (Tyvar.layout tyvar))),
		 fn ((f, t), ac) => (f, false, t) :: ac),
		Spine.canAddFields spine)
	    fun real _ = simple (str "real")
	    fun record (_, r) =
	       case Srecord.detupleOpt r of
		  NONE =>
		     layoutRecord (Vector.toListMap (Srecord.toVector r,
						     fn (f, t) => (f, false, t)),
				   false)
		| SOME ts => Tycon.layoutApp (Tycon.tuple, ts)
	    fun recursive _ = simple (str "<recur>")
	    fun unknown (_, u) = simple (str "???")
	    val {destroy, get = prettyTyvar, ...} =
	       Property.destGet
	       (Tyvar.plist,
		Property.initFun
		(let
		    val r = ref (Char.toInt #"a")
		 in
		    fn _ =>
		    let
		       val n = !r
		       val l =
			  simple
			  (str (concat ["'", Char.toString (Char.fromInt n)]))
		       val _ = r := 1 + n
		    in
		       l
		    end
		 end))
	    fun var (_, a) = prettyTyvar a
	    fun word _ = simple (str "word")
	    fun lay t =
	       hom (t, {con = con,
			expandOpaque = Never,
			flexRecord = flexRecord,
			genFlexRecord = genFlexRecord,
			int = int,
			real = real,
			record = record,
			recursive = recursive,
			unknown = unknown,
			var = var,
			word = word})
	 in
	    {destroy = destroy,
	     lay = lay}
	 end

      fun layoutPretty t =
	 let
	    val {destroy, lay} = makeLayoutPretty ()
	    val res = #1 (lay t)
	    val _ = destroy ()
	 in
	    res
	 end

      fun deConOpt t =
	 case toType t of
	    Con x => SOME x
	  | _ => NONE

      fun deEta (t: t, tyvars: Tyvar.t vector): Tycon.t option =
	 case deConOpt t of
	    SOME (c, ts) =>
	       if Vector.length ts = Vector.length tyvars
		  andalso Vector.foralli (ts, fn (i, t) =>
					  case toType t of
					     Var a =>
						Tyvar.equals
						(a, Vector.sub (tyvars, i))
					   | _ => false)
		  then SOME c
	       else NONE
           | _ => NONE


      fun newTy (ty: ty, eq: Equality.t): t =
	 T (Set.singleton {equality = eq,
			   plist = PropertyList.new (),
			   ty = ty})

      fun unknown {canGeneralize, equality} =
	 let
	    val t = newTy (Unknown (Unknown.new {canGeneralize = canGeneralize}),
			   equality)
	    val _ = List.push (freeUnknowns, t)
	 in
	    t
	 end

      fun new () = unknown {canGeneralize = true,
			    equality = Equality.unknown ()}

      fun newFlex {fields, spine} =
	 newTy (FlexRecord {fields = fields,
			    spine = spine,
			    time = ref (Time.now ())},
		Equality.and2
		(Equality.andd (Vector.fromListMap (fields, equality o #2)),
		 Equality.unknown ()))

      fun flexRecord record =
	 let
	    val v = Srecord.toVector record
	    val spine = Spine.new (Vector.toListMap (v, #1))
	    fun isResolved (): bool = not (Spine.canAddFields spine)
	    val t = newFlex {fields = Vector.toList v,
			     spine = spine}
	    val _ = List.push (freeFlexes, t)
	 in
	    (t, isResolved)
	 end
	 
      fun record r =
	 newTy (Record r,
		Equality.andd (Vector.map (Srecord.range r, equality)))

      fun tuple ts =
	 if 1 = Vector.length ts
	    then Vector.sub (ts, 0)
	 else newTy (Record (Srecord.tuple ts),
		     Equality.andd (Vector.map (ts, equality)))

      fun con (tycon, ts) =
	 if Tycon.equals (tycon, Tycon.tuple)
	    then tuple ts
	 else newTy (Con (tycon, ts),
		     Equality.applyTycon (tycon, Vector.map (ts, equality)))

      val char = con (Tycon.char, Vector.new0 ())
      val string = con (Tycon.vector, Vector.new1 char)

      fun var a = newTy (Var a, Equality.fromBool (Tyvar.isEquality a))
   end

fun setOpaqueTyconExpansion (c, f) =
   Type.setOpaqueTyconExpansion (c, SOME f)

structure Ops = TypeOps (structure IntSize = IntSize
			 structure Tycon = Tycon
			 structure WordSize = WordSize
			 open Type)

fun layoutTopLevel (t: Type.ty) =
   let
      val str = Layout.str
      datatype z = datatype Type.ty
   in
      case t of
	 Con (c, ts) =>
	    Tycon.layoutApp
	    (c, Vector.map (ts, fn t =>
			    if (case Type.toType t of
				   Con (c, _) => Tycon.equals (c, Tycon.char)
				 | _ => false)
			       then (str "_", {isChar = true,
					       needsParen = false})
			    else dontCare))
       | FlexRecord _ => simple (str "{...}")
       | GenFlexRecord _ => simple (str "{...}")
       | Int => simple (str "int")
       | Real => simple (str "real")
       | Record r =>
	    (case Srecord.detupleOpt r of
		NONE => simple (str "{...}")
	      | SOME ts => layoutTuple (Vector.map (ts, fn _ => dontCare)))
       | Unknown _ => Error.bug "layoutTopLevel Unknown"
       | Var a => simple (Tyvar.layout a)
       | Word => simple (str "word")
   end
   
structure Type =
   struct
      (* Order is important, since want specialized definitions in Type to
       * override general definitions in Ops.
       *)
      open Ops Type

      val char = con (Tycon.char, Vector.new0 ())
	 
      val unit = tuple (Vector.new0 ())

      fun isUnit t =
	 case toType t of
	    Record r =>
	       (case Srecord.detupleOpt r of
		   NONE => false
		 | SOME v => 0 = Vector.length v)
	  | _ => false

      val equals: t * t -> bool = fn (T s, T s') => Set.equals (s, s')

      local
	 fun make ty () = newTy ty
      in
	 val unresolvedInt = make (Int, Equality.truee)
	 val unresolvedReal = make (Real, Equality.falsee)
	 val unresolvedWord = make (Word, Equality.truee)
      end
   
      val traceCanUnify =
	 Trace.trace2 ("canUnify", layout, layout, Bool.layout)

      fun canUnify arg = 
	 traceCanUnify
	 (fn (t, t') =>
	  case (toType t, toType t') of
	     (Unknown _,  _) => true
	   | (_, Unknown _) => true
	   | (Con (c, ts), t') => conAnd (c, ts, t')
	   | (t', Con (c, ts)) => conAnd (c, ts, t')
	   | (Int, Int) => true
	   | (Real, Real) => true
	   | (Record r, Record r') =>
		let
		   val fs = Srecord.toVector r
		   val fs' = Srecord.toVector r'
		in Vector.length fs = Vector.length fs'
		   andalso Vector.forall2 (fs, fs', fn ((f, t), (f', t')) =>
					   Field.equals (f, f')
					   andalso canUnify (t, t'))
		end
	   | (Var a, Var a') => Tyvar.equals (a, a')
	   | (Word, Word) => true
	   | _ => false) arg
      and conAnd (c, ts, t') =
	 case t' of
	    Con (c', ts') =>
	       Tycon.equals (c, c')
	       andalso Vector.forall2 (ts, ts', canUnify)
	  | Int => 0 = Vector.length ts andalso Tycon.isIntX c
	  | Real => 0 = Vector.length ts andalso Tycon.isRealX c
	  | Word => 0 = Vector.length ts andalso Tycon.isWordX c
	  | _ => false

      fun minTime (t, time) =
	 let
	    fun doit r = r := Time.min (!r, time)
	    fun var (_, a) = doit (tyvarTime a)
	    val {destroy, hom} =
	       makeHom
	       {con = fn _ => (),
		expandOpaque = Never,
		flexRecord = fn (_, {time = r, ...}) => doit r,
		genFlexRecord = fn _ => (),
		int = fn _ => (),
		real = fn _ => (),
		record = fn _ => (),
		recursive = fn _ => (),
		unknown = fn (_, u) => Unknown.minTime (u, time),
		var = var,
		word = fn _ => ()}
	    val _ = hom t
	    val _ = destroy ()
	 in
	    ()
	 end

      datatype z = datatype UnifyResult.t

      val traceUnify = Trace.trace2 ("unify", layout, layout, UnifyResult.layout)

      fun unify (t, t', preError: unit -> unit): UnifyResult.t =
	 let
	    val {destroy, lay = layoutPretty} = makeLayoutPretty ()
	    val dontCare' =
	       case !Control.typeError of
		  Control.Concise => (fn _ => dontCare)
		| Control.Full => layoutPretty
	    val layoutRecord =
	       fn z => layoutRecord (z,
				     case !Control.typeError of
					Control.Concise => true
				      | Control.Full => false)
	    fun unify arg =
	       traceUnify
	       (fn (outer as T s, outer' as T s') =>
		if Set.equals (s, s')
		   then Unified
		else
		   let
		      fun notUnifiable (l: Lay.t, l': Lay.t) =
			 (NotUnifiable (l, l'),
			  Unknown (Unknown.new {canGeneralize = true}))
		      val bracket =
			 fn (l, {isChar, needsParen}) =>
			 (bracket l,
			  {isChar = isChar,
			   needsParen = false})
		      fun notUnifiableBracket (l, l') =
			 notUnifiable (bracket l, bracket l')
		      fun flexToRecord (fields, spine) =
			 (Vector.fromList fields,
			  Vector.fromList
			  (List.fold
			   (Spine.fields spine, [], fn (f, ac) =>
			    if List.exists (fields, fn (f', _) =>
					    Field.equals (f, f'))
			       then ac
			    else f :: ac)),
			  fn f => Spine.ensureField (spine, f))
		      fun rigidToRecord r =
			 (Srecord.toVector r,
			  Vector.new0 (),
			  fn f => isSome (Srecord.peek (r, f)))
		      fun oneFlex ({fields, spine, time}, r, outer, swap) =
			 let
			    val _ = minTime (outer, !time)
			 in
			    unifyRecords
			    (flexToRecord (fields, spine),
			     rigidToRecord r,
			     fn () => (Spine.noMoreFields spine
				       ; (Unified, Record r)),
			     fn (l, l') => notUnifiable (if swap
							    then (l', l)
							 else (l, l')))
			 end
		      fun genFlexError () =
			 Error.bug "GenFlexRecord seen in unify"
		      val {equality = e, ty = t, plist} = Set.value s
		      val {equality = e', ty = t', ...} = Set.value s'
		      fun not () =
			 (preError ()
			  ; notUnifiableBracket (layoutPretty outer,
						 layoutPretty outer'))
		      fun unifys (ts, ts', yes, no) =
			 let
			    val us = Vector.map2 (ts, ts', unify)
			 in
			    if Vector.forall
			       (us, fn Unified => true | _ => false)
			       then yes ()
			    else
			       let
				  val (ls, ls') =
				     Vector.unzip
				     (Vector.mapi
				      (us, fn (i, u) =>
				       case u of
					  Unified =>
					     let
						val z =
						   dontCare' (Vector.sub (ts, i))
					     in
						(z, z)
					     end
					| NotUnifiable (l, l') => (l, l')))
			       in
				  no (ls, ls')
			       end
			 end
		      fun conAnd (c, ts, t, t', swap) =
			 let
			    fun maybe (z, z') =
			       if swap then (z', z) else (z, z')
			 in
			    case t of
			       Con (c', ts') =>
				  if Tycon.equals (c, c')
				     then
					if Vector.length ts <> Vector.length ts'
					   then
					      let
						 fun lay ts =
						    simple
						    (Layout.seq
						     [Layout.str
						      (concat ["<",
							       Int.toString
							       (Vector.length ts),
							       " args> "]),
						      Tycon.layout c])
						 val _ = preError ()
					      in
						 notUnifiableBracket
						 (maybe (lay ts, lay ts'))
					      end
					else
					   unifys
					   (ts, ts',
					    fn () => (Unified, t),
					    fn (ls, ls') =>
					    let 
					       fun lay ls =
						  Tycon.layoutApp (c, ls)
					    in
					       notUnifiable
					       (maybe (lay ls, lay ls'))
					    end)
				  else not ()
			     | Int =>
				  if Tycon.isIntX c andalso Vector.isEmpty ts
				     then (Unified, t')
				  else not ()
			     | Real =>
				  if Tycon.isRealX c andalso Vector.isEmpty ts
				     then (Unified, t')
				  else not ()
			     | Word =>
				  if Tycon.isWordX c andalso Vector.isEmpty ts
				     then (Unified, t')
				  else not ()
			     | _ => not ()
			 end
		      fun oneUnknown (u, t, outer) =
			 let
			    val _ = minTime (outer, Unknown.time u)
			 in
			    (Unified, t)
			 end
		      val (res, t) =
			 case (t, t') of
			    (Unknown r, Unknown r') =>
			       (Unified, Unknown (Unknown.join (r, r')))
			  | (_, Unknown u) => oneUnknown (u, t, outer)
			  | (Unknown u, _) => oneUnknown (u, t', outer')
			  | (Con (c, ts), _) => conAnd (c, ts, t', t, false)
			  | (_, Con (c, ts)) => conAnd (c, ts, t, t', true)
			  | (FlexRecord f, Record r) =>
			       oneFlex (f, r, outer', false)
			  | (Record r, FlexRecord f) =>
			       oneFlex (f, r, outer, true)
			  | (FlexRecord {fields = fields, spine = s, time = t},
			     FlexRecord {fields = fields', spine = s',
					 time = t', ...}) =>
			    let
			       fun yes () =
				  let
				     val _ = Spine.unify (s, s')
				     val fields =
					List.fold
					(fields, fields', fn ((f, t), ac) =>
					 if List.exists (fields', fn (f', _) =>
							 Field.equals (f, f'))
					    then ac
					 else (f, t) :: ac)
				  in
				     (Unified,
				      FlexRecord
				      {fields = fields,
				       spine = s,
				       time = ref (Time.min (!t, !t'))})
				  end
			    in
			       unifyRecords
			       (flexToRecord (fields, s),
				flexToRecord (fields', s'),
				yes, notUnifiable)
			    end
			  | (GenFlexRecord _, _) => genFlexError ()
			  | (_, GenFlexRecord _) => genFlexError ()
			  | (Int, Int) => (Unified, Int)
			  | (Real, Real) => (Unified, Real)
			  | (Record r, Record r') =>
			       (case (Srecord.detupleOpt r,
				      Srecord.detupleOpt r') of
				   (NONE, NONE) =>
				      unifyRecords
				      (rigidToRecord r, rigidToRecord r',
				       fn () => (Unified, Record r),
				       notUnifiable)
				 | (SOME ts, SOME ts') =>
				      if Vector.length ts = Vector.length ts'
					 then
					    unifys
					    (ts, ts',
					     fn () => (Unified, Record r),
					     fn (ls, ls') =>
					     notUnifiable (layoutTuple ls,
							   layoutTuple ls'))
				      else not ()
				 | _ => not ())
			  | (Var a, Var a') =>
			       if Tyvar.equals (a, a')
				  then (Unified, t)
			       else not ()
			  | (Word, Word) => (Unified, Word)
			  | _ => not ()
		      val res =
			 case res of
			    NotUnifiable _ => res
			  | Unified =>
			       let
				  val res = Equality.unify (e, e')
				  val _ =
				     case res of
					NotUnifiable _ => ()
				      | Unified => 
					   (Set.union (s, s')
					    ;  Set.setValue (s, {equality = e,
								 plist = plist,
								 ty = t}))
			       in
				  res
			       end
		   in
		      res
		   end) arg
	    and unifyRecords ((fields: (Field.t * t) vector,
			       extra: Field.t vector,
			       ensureField: Field.t -> bool),
			      (fields': (Field.t * t) vector,
			       extra': Field.t vector,
			       ensureField': Field.t -> bool),
			      yes, no) =
	       let
		  fun extras (extra, ensureField') =
		     Vector.fold
		     (extra, [], fn (f, ac) =>
		      if ensureField' f
			 then ac
		      else (preError (); (f, true, dontCare) :: ac))
		  val ac = extras (extra, ensureField')
		  val ac' = extras (extra', ensureField)
		  fun subset (fields, fields', ensureField', ac, ac',
			      both, skipBoth) =
		     Vector.fold
		     (fields, (ac, ac', both), fn ((f, t), (ac, ac', both)) =>
		      case Vector.peek (fields', fn (f', _) =>
					Field.equals (f, f')) of
			 NONE =>
			    if ensureField' f
			       then (ac, ac', both)
			    else (preError ()
				  ; ((f, true, dontCare' t) :: ac, ac', both))
		       | SOME (_, t') =>
			    if skipBoth
			       then (ac, ac', both)
			    else
			       case unify (t, t') of
				  NotUnifiable (l, l') =>
				     ((f, false, l) :: ac,
				      (f, false, l') :: ac',
				      both)
				| Unified =>
				     (ac, ac',
				      case !Control.typeError of
					 Control.Concise => []
				       | Control.Full => (f, t) :: both))
		  val (ac, ac', both) =
		     subset (fields, fields', ensureField', ac, ac', [], false)
		  val (ac', ac, both) =
		     subset (fields', fields, ensureField, ac', ac, both, true)
	       in
		  case (ac, ac') of
		     ([], []) => yes ()
		   | _ =>
			let
			   val _ = preError ()
			   fun doit ac =
			      layoutRecord (List.fold
					    (both, ac, fn ((f, t), ac) =>
					     (f, false, layoutPretty t) :: ac))
			in
			   no (doit ac, doit ac')
			end
	       end
	    val _ = destroy ()
	 in
	    unify (t, t')
	 end

      structure UnifyResult' =
	 struct
	    datatype t =
	       NotUnifiable of Layout.t * Layout.t
	     | Unified

	    val layout =
	       let
		  open Layout
	       in
		  fn NotUnifiable _ => str "NotUnifiable"
		   | Unified => str "Unified"
	       end
	 end

      datatype unifyResult = datatype UnifyResult'.t

      val unify =
	 fn (t, t', preError) =>
	 case unify (t, t', preError) of
	    UnifyResult.NotUnifiable ((l, _), (l', _)) => NotUnifiable (l, l')
	  | UnifyResult.Unified => Unified

      val word8 = word WordSize.W8
	 
      fun 'a simpleHom {con: t * Tycon.t * 'a vector -> 'a,
			expandOpaque: expandOpaque,
			record: t * (Field.t * 'a) vector -> 'a,
			replaceCharWithWord8: bool,
			var: t * Tyvar.t -> 'a} =
	 let
	    val con =
	       fn (t, c, ts) =>
	       if replaceCharWithWord8 andalso Tycon.equals (c, Tycon.char)
		  then con (word8, Tycon.word WordSize.W8, Vector.new0 ())
	       else con (t, c, ts)
	    val unit = con (unit, Tycon.tuple, Vector.new0 ())
	    val unknown = unit
	    fun sortFields (fields: (Field.t * 'a) list) =
	       Array.toVector
	       (QuickSort.sortArray
		(Array.fromList fields, fn ((f, _), (f', _)) =>
		 Field.<= (f, f')))
	    fun unsorted (t, fields: (Field.t *  'a) list) =
	       let
		  val v = sortFields fields
	       in
		  record (t, v)
	       end
	    fun genFlexRecord (t, {extra, fields, spine}) =
	       unsorted (t,
			 List.fold
			 (extra (), fields, fn ({field, tyvar}, ac) =>
			  (field, var (Type.var tyvar, tyvar)) :: ac))
	    fun flexRecord (t, {fields, spine, time}) =
	       if Spine.canAddFields spine
		  then Error.bug "Type.hom flexRecord"
	       else unsorted (t,
			      Spine.foldOverNew
			      (spine, fields, fields, fn (f, ac) =>
			       (f, unit) :: ac))
	    fun recursive t = Error.bug "Type.hom recursive"
	    val int =
	       con (int IntSize.default, Tycon.defaultInt, Vector.new0 ())
	    val real =
	       con (real RealSize.default, Tycon.defaultReal, Vector.new0 ())
	    val word =
	       con (word WordSize.default, Tycon.defaultWord, Vector.new0 ())
	 in
	    makeHom {con = con,
		     expandOpaque = expandOpaque,
		     int = fn _ => int,
		     flexRecord = flexRecord,
		     genFlexRecord = genFlexRecord,
		     real = fn _ => real,
		     record = fn (t, r) => record (t, Srecord.toVector r),
		     recursive = recursive,
		     unknown = fn _ => unknown,
		     var = var,
		     word = fn _ => word}
	 end
   end

structure Scheme =
   struct
      datatype t =
	 General of {bound: unit -> Tyvar.t vector,
		     canGeneralize: bool,
		     flexes: Type.genFlexRecord list,
		     tyvars: Tyvar.t vector,
		     ty: Type.t}
       | Type of Type.t
      
      fun layout s =
	 case s of
	    Type t => Type.layout t
	  | General {canGeneralize, tyvars, ty, ...} =>
	       Layout.record [("canGeneralize", Bool.layout canGeneralize),
			      ("tyvars", Vector.layout Tyvar.layout tyvars),
			      ("ty", Type.layout ty)]

      fun layoutPretty s =
	 case s of
	    Type t => Type.layoutPretty t
	  | General {ty, ...} => Type.layoutPretty ty

      val tyvars =
	 fn General {tyvars, ...} => tyvars
	  | Type _ => Vector.new0 ()
	 
      val bound =
	 fn General {bound, ...} => bound ()
	  | Type _ => Vector.new0 ()

      val bound =
	 Trace.trace ("Scheme.bound", layout, Vector.layout Tyvar.layout)
	 bound

      val ty =
	 fn General {ty, ...} => ty
	  | Type ty => ty

      fun dest s = (bound s, ty s)

      fun make {canGeneralize, tyvars, ty} =
	 if 0 = Vector.length tyvars
	    then Type ty
	 else General {bound = fn () => tyvars,
		       canGeneralize = canGeneralize,
		       flexes = [],
		       tyvars = tyvars,
		       ty = ty}

      val fromType = Type

      fun instantiate' (t: t, subst) =
	 case t of
	    Type ty => {args = fn () => Vector.new0 (),
			instance = ty}
	  | General {canGeneralize, flexes, tyvars, ty, ...} =>
	       let
		  open Type
		  val {destroy = destroyTyvarInst,
		       get = tyvarInst: Tyvar.t -> Type.t option,
		       set = setTyvarInst} =
		     Property.destGetSetOnce (Tyvar.plist,
					      Property.initConst NONE)
		  val types =
		     Vector.mapi
		     (tyvars, fn (i, a) =>
		      let
			 val t = subst {canGeneralize = canGeneralize,
					equality = Tyvar.isEquality a,
					index = i}
			 val _ = setTyvarInst (a, SOME t)
		      in
			 t
		      end)
		  type z = {isNew: bool, ty: Type.t}
		  fun isNew {isNew = b, ty} = b
		  fun keep ty = {isNew = false, ty = ty}
		  fun con (ty, c, zs) =
		     if Vector.exists (zs, isNew)
			then {isNew = true,
			      ty = Type.con (c, Vector.map (zs, #ty))}
		     else keep ty
		  val flexInsts = ref []
		  fun genFlexRecord (t, {extra, fields, spine}) =
		     let
			val fields = List.revMap (fields, fn (f, t: z) =>
						  (f, #ty t))
			val flex = newFlex {fields = fields,
					    spine = spine}
			val _ = List.push (flexInsts, {flex = flex,
						       spine = spine})
		     in
			{isNew = true,
			 ty = flex}
		     end
		  fun record (t, r) =
		     if Srecord.exists (r, isNew)
			then {isNew = true,
			      ty = Type.record (Srecord.map (r, #ty))}
		     else keep t
		  fun recursive t =
		     Error.bug "instantiating recursive type"
		  fun var (ty, a) =
		     case tyvarInst a of
			NONE => {isNew = false, ty = ty}
		      | SOME ty => {isNew = true, ty = ty}
		  val {ty: Type.t, ...} =
		     Type.hom (ty, {con = con,
				    expandOpaque = Never,
				    flexRecord = keep o #1,
				    genFlexRecord = genFlexRecord,
				    int = keep,
				    real = keep,
				    record = record,
				    recursive = recursive,
				    unknown = keep o #1,
				    var = var,
				    word = keep})
		  val _ = destroyTyvarInst ()
		  val flexInsts = !flexInsts
		  fun args (): Type.t vector =
		     Vector.fromList
		     (List.fold
		      (flexes, Vector.toList types,
		       fn ({fields, spine, ...}, ac) =>
		       let
			  val flex =
			     case List.peek (flexInsts,
					     fn {spine = spine', ...} =>
					     Spine.equals (spine, spine')) of
				NONE => Error.bug "missing flexInst"
			      | SOME {flex, ...} => flex
			  fun peekFields (fields, f) =
			     Option.map
			     (List.peek (fields, fn (f', _) =>
					 Field.equals (f, f')),
			      #2)
			  val peek =
			     case Type.toType flex of
				FlexRecord {fields, ...} =>
				   (fn f => peekFields (fields, f))
			      | GenFlexRecord {extra, fields, ...} =>
				   (fn f =>
				    case peekFields (fields, f) of
				       NONE =>
					  Option.map
					  (List.peek
					   (extra (), fn {field, ...} =>
					    Field.equals (f, field)),
					   Type.var o #tyvar)
				     | SOME t => SOME t)
			      | Record r => (fn f => Srecord.peek (r, f))
			      | _ => Error.bug "strange flexInst"
		       in
			  Spine.foldOverNew
			  (spine, fields, ac, fn (f, ac) =>
			   (case peek f of
			       NONE => Type.unit
			     | SOME t => t) :: ac)
		       end))
	       in
		  {args = args,
		   instance = ty}
	       end

      fun apply (s, ts) =
	 #instance (instantiate' (s, fn {index, ...} => Vector.sub (ts, index)))
	 
      fun instantiate s =
	 instantiate'
	 (s, fn {canGeneralize, equality, ...} =>
	  Type.unknown {canGeneralize = canGeneralize,
			equality = if equality
				      then Equality.truee
				   else Equality.unknown ()})

      val instantiate =
	 Trace.trace ("Scheme.instantiate", layout, Type.layout o #instance)
	 instantiate

      fun admitsEquality s =
	 Type.admitsEquality
	 (#instance
	  (instantiate'
	   (s, fn {canGeneralize, equality, ...} =>
	    Type.unknown {canGeneralize = canGeneralize,
			  equality = Equality.truee})))

      fun haveFrees (v: t vector): bool vector =
	 let
	    exception Yes
	    val {destroy, hom} =
	       Type.makeHom {con = fn _ => (),
			     expandOpaque = Type.Never,
			     flexRecord = fn _ => (),
			     genFlexRecord = fn _ => (),
			     int = fn _ => (),
			     real = fn _ => (),
			     record = fn _ => (),
			     recursive = fn _ => (),
			     unknown = fn _ => raise Yes,
			     var = fn _ => (),
			     word = fn _ => ()}
	    val res =
	       Vector.map (v, fn s =>
			   let
			      val _ =
				 case s of
				    General {ty, ...} => hom ty
				  | Type ty => hom ty
			   in
			      false
			   end handle Yes => true)
	    val _ = destroy ()
	 in
	    res
	 end
   end

fun close (ensure: Tyvar.t vector, region)
   : Type.t vector -> {bound: unit -> Tyvar.t vector,
		       schemes: Scheme.t vector} =
   let
      val genTime = Time.tick ()
      val _ = Vector.foreach (ensure, fn a => (tyvarTime a; ()))
   in
      fn tys =>
      let
	 val unable =
	    Vector.keepAll (ensure, fn a =>
			    not (Time.<= (genTime, !(tyvarTime a))))
	 val _ = 
	    if Vector.length unable > 0
	       then
		  let
		     open Layout
		  in
		     Control.error
		     (region,
		      seq [str "unable to generalize ",
			   seq (List.separate (Vector.toListMap (unable,
								 Tyvar.layout),
					       str ", "))],
		      empty)
		  end
	    else ()
	 (* Convert all the unknown types bound at this level into tyvars. *)
	 val (tyvars, ac) =
	    List.fold
	    (!Type.freeUnknowns, (Vector.toList ensure, []),
	     fn (t, (tyvars, ac)) =>
	     case Type.toType t of
		Type.Unknown (Unknown.T {canGeneralize, time, ...}) =>
		   if canGeneralize andalso Time.<= (genTime, !time)
		      then
			 let
			    val equality = Type.equality t
			    val b =
			       case Equality.toBoolOpt equality of
				  NONE =>
				     (Equality.unify (equality, Equality.falsee)
				      ; false)
				| SOME b => b
			    val a = Tyvar.newNoname {equality = b}
			    val _ = Type.set (t, {equality = equality,
						  plist = PropertyList.new (),
						  ty = Type.Var a})
			 in
			    (a :: tyvars, ac)
			 end
		   else (tyvars, t :: ac)
	      | _ => (tyvars, ac))
	 val _ = Type.freeUnknowns := ac
	 (* Convert all the FlexRecords bound at this level into GenFlexRecords.
	  *)
	 val (flexes, ac) =
	    List.fold
	    (!Type.freeFlexes, ([], []), fn (t as Type.T s, (flexes, ac)) =>
	     let
		val {equality, plist, ty} = Set.value s
	     in
		case ty of
		   Type.FlexRecord {fields, spine, time, ...} =>
		      if Time.<= (genTime, !time)
			 then
			    let
			       val extra =
				  Promise.lazy
				  (fn () =>
				   Spine.foldOverNew
				   (spine, fields, [], fn (f, ac) =>
				    {field = f,
				     tyvar = Tyvar.newNoname {equality = false}}
				    :: ac))
			       val gfr = {extra = extra,
					  fields = fields,
					  spine = spine}
			       val _ = 
				  Set.setValue
				  (s, {equality = equality,
				       plist = plist,
				       ty = Type.GenFlexRecord gfr})
			    in
			       (gfr :: flexes, ac)
			    end
		      else (flexes, t :: ac)
                  | _ => (flexes, ac)
	     end)
	 val _ = Type.freeFlexes := ac
	 (* For all fields that were added to the generalized flex records, add
	  * a type variable.
	  *)
	 fun bound () =
	    Vector.fromList
	    (List.fold
	     (flexes, tyvars, fn ({extra, fields, spine}, ac) =>
	      let
		 val extra = extra ()
	      in
		 Spine.foldOverNew
		 (spine, fields, ac, fn (f, ac) =>
		  case List.peek (extra, fn {field, ...} =>
				  Field.equals (f, field)) of
		     NONE => Error.bug "GenFlex missing field"
		   | SOME {tyvar, ...} => tyvar :: ac)
	      end))
	 val schemes =
	    Vector.map
	    (tys, fn ty =>
	     Scheme.General {bound = bound,
			     canGeneralize = true,
			     flexes = flexes,
			     tyvars = Vector.fromList tyvars,
			     ty = ty})
      in
	 {bound = bound,
	  schemes = schemes}
      end
   end

fun closeTop (r: Region.t): unit =
   let
      val _ =
	 List.foreach
	 (!Type.freeUnknowns, fn t =>
	  case Type.toType t of
	     Type.Unknown _ => (Type.unify (t, Type.unit, fn () => ())
				; ())
	   | _ => ())
      val _ = Type.freeUnknowns := []
      val _ = List.foreach (!Type.freeFlexes, fn t =>
			    case Type.toType t of
 			       Type.FlexRecord _ => Error.bug "free flex\n"
			     | _ => ())
      val _ = Type.freeFlexes := []
   in
      ()
   end

structure Type =
   struct
      open Type

      fun homConVar {con, expandOpaque, var} =
	 let
	    fun tuple (t, ts) =
	       if 1 = Vector.length ts
		  then Vector.sub (ts, 0)
	       else con (t, Tycon.tuple, ts)
	 in
	    simpleHom {con = con,
		       expandOpaque = expandOpaque,
		       record = fn (t, fs) => tuple (t, Vector.map (fs, #2)),
		       replaceCharWithWord8 = true,
		       var = var}
	 end

      fun makeHom {con, expandOpaque, var} =
	 homConVar {con = fn (_, c, ts) => con (c, ts),
		    expandOpaque = expandOpaque,
		    var = fn (_, a) => var a}
	 
      fun deRecord t =
	 let
	    val {hom, destroy} =
	       simpleHom
	       {con = fn (t, _, _) => (t, NONE),
		expandOpaque = Never,
		record = fn (t, fs) => (t,
					SOME (Vector.map (fs, fn (f, (t, _)) =>
							  (f, t)))),
		replaceCharWithWord8 = true,
		var = fn (t, _) => (t, NONE)}
	    val res =
	       case #2 (hom t) of
		  NONE => Error.bug "Type.deRecord"
		| SOME fs => fs
	    val _ = destroy ()
	 in
	    res
	 end

      fun deTupleOpt t =
	 let
	    val {destroy, hom} =
	       homConVar
	       {con = fn (t, c, ts) => (t,
					if Tycon.equals (c, Tycon.tuple)
					   then SOME (Vector.map (ts, #1))
					else NONE),
		expandOpaque = Never,
                var = fn (t, _) => (t, NONE)}
	    val res = #2 (hom t)
	    val _ = destroy ()
	 in
	    res
	 end

      val deTupleOpt =
	 Trace.trace ("Type.deTupleOpt", layout,
		      Option.layout (Vector.layout layout))
	 deTupleOpt

      val deTuple = valOf o deTupleOpt

      fun hom (t, {con, expandOpaque, record, var}) =
	 let
	    val {hom, destroy} =
	       simpleHom {con = fn (_, c, v) => con (c, v),
			  expandOpaque = expandOpaque,
			  record = fn (_, fs) => record (Srecord.fromVector fs),
			  replaceCharWithWord8 = false,
			  var = fn (_, a) => var a}
	    val res = hom t
	    val _ = destroy ()
	 in
	    res
	 end

      fun expandOpaque (t: t, e): t =
	 hom (t, {con = con, expandOpaque = e, record = record, var = var})

      val expandOpaque =
	 Trace.trace ("expandOpaque", layoutPretty o #1, layoutPretty)
	 expandOpaque

      val unify =
	 fn (t1: t, t2: t, preError: unit -> unit,
	     f: Layout.t * Layout.t -> Region.t * Layout.t * Layout.t) =>
	 case unify (t1, t2, preError) of
	    NotUnifiable z => Control.error (f z)
	  | Unified => ()
   end

end
