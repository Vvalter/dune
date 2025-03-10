open Import

module Config : sig
  type t

  val all : t list

  val path : t -> string

  val of_string : string -> t

  val of_flags : string list -> t

  val to_flags : t -> string list
end = struct
  type t =
    { js_string : bool option
    ; effects : bool option
    }

  let default = { js_string = None; effects = None }

  let bool_opt = [ None; Some true; Some false ]

  let all =
    List.concat_map bool_opt ~f:(fun js_string ->
        List.concat_map bool_opt ~f:(fun effects -> [ { js_string; effects } ]))

  let get t =
    List.filter_map
      [ ("use-js-string", t.js_string); ("effects", t.effects) ]
      ~f:(fun (n, v) ->
        match v with
        | None -> None
        | Some v -> Some (n, v))

  let set acc name v =
    match name with
    | "use-js-string" -> { acc with js_string = Some v }
    | "effects" -> { acc with effects = Some v }
    | _ -> acc

  let path t =
    if t = default then "default"
    else
      List.map (get t) ~f:(function
        | x, true -> x
        | x, false -> "!" ^ x)
      |> String.concat ~sep:"+"

  let of_string x =
    match x with
    | "default" -> default
    | _ ->
      List.fold_left (String.split ~on:'+' x) ~init:default ~f:(fun acc name ->
          match String.drop_prefix ~prefix:"!" name with
          | Some name -> set acc name false
          | None -> set acc name true)

  let of_flags l =
    let rec loop acc = function
      | [] -> acc
      | "--enable" :: name :: rest -> loop (set acc name true) rest
      | "--disable" :: name :: rest -> loop (set acc name false) rest
      | _ :: rest -> loop acc rest
    in
    loop default l

  let to_flags t =
    List.concat_map (get t) ~f:(function
      | name, true -> [ "--enable"; name ]
      | name, false -> [ "--disable"; name ])
end

let install_jsoo_hint = "opam install js_of_ocaml-compiler"

let in_build_dir ~sctx ~config args =
  let ctx = Super_context.context sctx in
  Path.Build.L.relative ctx.Context.build_dir
    (".js" :: Config.path config :: args)

let in_obj_dir ~obj_dir ~config args =
  let dir =
    match config with
    | None -> Obj_dir.jsoo_dir obj_dir
    | Some config ->
      Path.Build.relative (Obj_dir.jsoo_dir obj_dir) (Config.path config)
  in
  Path.Build.L.relative dir args

let in_obj_dir' ~obj_dir ~config args =
  let dir =
    match config with
    | None -> Obj_dir.jsoo_dir obj_dir
    | Some config ->
      Path.relative (Obj_dir.jsoo_dir obj_dir) (Config.path config)
  in
  Path.L.relative dir args

let jsoo ~dir sctx =
  Super_context.resolve_program sctx ~dir ~loc:None ~hint:install_jsoo_hint
    "js_of_ocaml"

type sub_command =
  | Compile
  | Link
  | Build_runtime

let js_of_ocaml_rule sctx ~sub_command ~dir ~(flags : _ Js_of_ocaml.Flags.t)
    ~config ~spec ~target =
  let open Memo.O in
  let+ jsoo = jsoo ~dir sctx
  and+ flags = Super_context.js_of_ocaml_flags sctx ~dir flags in
  Command.run ~dir:(Path.build dir) jsoo
    [ (match sub_command with
      | Compile -> S []
      | Link -> A "link"
      | Build_runtime -> A "build-runtime")
    ; Command.Args.dyn
        (match sub_command with
        | Compile -> flags.compile
        | Link -> flags.link
        | Build_runtime -> flags.build_runtime)
    ; (match config with
      | None -> S []
      | Some config ->
        Dyn
          (Action_builder.map config ~f:(fun config ->
               Command.Args.S
                 (List.map (Config.to_flags config) ~f:(fun x ->
                      Command.Args.A x)))))
    ; A "-o"
    ; Target target
    ; spec
    ]

let jsoo_runtime_files =
  List.concat_map ~f:(fun t -> Lib_info.jsoo_runtime (Lib.info t))

let standalone_runtime_rule cc ~javascript_files ~target ~flags =
  let dir = Compilation_context.dir cc in
  let sctx = Compilation_context.super_context cc in
  let config =
    Action_builder.of_memo_join
      (Memo.map
         ~f:(fun x -> x.compile)
         (Super_context.js_of_ocaml_flags sctx ~dir flags))
    |> Action_builder.map ~f:Config.of_flags
  in
  let libs = Compilation_context.requires_link cc in
  let spec =
    Command.Args.S
      [ Resolve.Memo.args
          (let open Resolve.Memo.O in
          let+ libs = libs in
          Command.Args.Deps (jsoo_runtime_files libs))
      ; Deps (List.map ~f:Path.build javascript_files)
      ]
  in
  let dir = Compilation_context.dir cc in
  js_of_ocaml_rule
    (Compilation_context.super_context cc)
    ~sub_command:Build_runtime ~dir ~flags ~target ~spec ~config:(Some config)

let exe_rule cc ~javascript_files ~src ~target ~flags =
  let dir = Compilation_context.dir cc in
  let sctx = Compilation_context.super_context cc in
  let libs = Compilation_context.requires_link cc in
  let spec =
    Command.Args.S
      [ Resolve.Memo.args
          (let open Resolve.Memo.O in
          let+ libs = libs in
          Command.Args.Deps (jsoo_runtime_files libs))
      ; Deps (List.map ~f:Path.build javascript_files)
      ; Dep (Path.build src)
      ]
  in
  js_of_ocaml_rule sctx ~sub_command:Compile ~dir ~spec ~target ~flags
    ~config:None

let with_js_ext s =
  match Filename.split_extension s with
  | name, ".cma" -> name ^ Js_of_ocaml.Ext.cma
  | name, ".cmo" -> name ^ Js_of_ocaml.Ext.cmo
  | _ -> assert false

let jsoo_archives ~sctx config lib =
  let info = Lib.info lib in
  let archives = Lib_info.archives info in
  match Lib.is_local lib with
  | true ->
    let obj_dir = Lib_info.obj_dir info in
    List.map archives.byte ~f:(fun archive ->
        in_obj_dir' ~obj_dir ~config:(Some config)
          [ with_js_ext (Path.basename archive) ])
  | false ->
    List.map archives.byte ~f:(fun archive ->
        Path.build
          (in_build_dir ~sctx ~config
             [ Lib_name.to_string (Lib.name lib)
             ; with_js_ext (Path.basename archive)
             ]))

let link_rule cc ~runtime ~target ~obj_dir cm ~flags ~link_time_code_gen =
  let sctx = Compilation_context.super_context cc in
  let dir = Compilation_context.dir cc in
  let requires = Compilation_context.requires_link cc in
  let special_units = Action_builder.of_memo link_time_code_gen in
  let config =
    Action_builder.of_memo_join
      (Memo.map
         ~f:(fun x -> x.compile)
         (Super_context.js_of_ocaml_flags sctx ~dir flags))
    |> Action_builder.map ~f:Config.of_flags
  in
  let mod_name m =
    Module_name.Unique.artifact_filename (Module.obj_name m)
      ~ext:Js_of_ocaml.Ext.cmo
  in
  let get_all =
    Action_builder.map
      (Action_builder.both (Action_builder.both cm special_units) config)
      ~f:(fun ((cm, special_units), config) ->
        Resolve.Memo.args
          (let open Resolve.Memo.O in
          let+ libs = requires in
          (* Special case for the stdlib because it is not referenced in the
             META *)
          let stdlib =
            Path.build
              (in_build_dir ~sctx ~config
                 [ "stdlib"; "stdlib" ^ Js_of_ocaml.Ext.cma ])
          in
          let special_units =
            List.concat_map special_units ~f:(function
              | Lib_flags.Lib_and_module.Lib _lib -> []
              | Module (obj_dir, m) ->
                [ in_obj_dir' ~obj_dir ~config:None [ mod_name m ] ])
          in
          let all_libs = List.concat_map libs ~f:(jsoo_archives ~sctx config) in

          let all_other_modules =
            List.map cm ~f:(fun m ->
                Path.build (in_obj_dir ~obj_dir ~config:None [ mod_name m ]))
          in
          let std_exit =
            Path.build
              (in_build_dir ~sctx ~config
                 [ "stdlib"; "std_exit" ^ Js_of_ocaml.Ext.cmo ])
          in
          Command.Args.Deps
            (List.concat
               [ [ stdlib ]
               ; special_units
               ; all_libs
               ; all_other_modules
               ; [ std_exit ]
               ])))
  in
  let spec = Command.Args.S [ Dep (Path.build runtime); Dyn get_all ] in
  js_of_ocaml_rule sctx ~sub_command:Link ~dir ~spec ~target ~flags ~config:None

let build_cm' sctx ~dir ~in_context ~src ~target ~config =
  let spec = Command.Args.Dep src in
  let flags = in_context.Js_of_ocaml.In_context.flags in
  js_of_ocaml_rule sctx ~sub_command:Compile ~dir ~flags ~spec ~target ~config

let build_cm sctx ~dir ~in_context ~src ~obj_dir ~config =
  let name = with_js_ext (Path.basename src) in
  let target = in_obj_dir ~obj_dir ~config [ name ] in
  build_cm' sctx ~dir ~in_context ~src ~target
    ~config:(Option.map config ~f:Action_builder.return)

let setup_separate_compilation_rules sctx components =
  match components with
  | _ :: _ :: _ :: _ | [] | [ _ ] -> Memo.return ()
  | [ s_config; s_pkg ] -> (
    let config = Config.of_string s_config in
    let pkg = Lib_name.parse_string_exn (Loc.none, s_pkg) in
    let ctx = Super_context.context sctx in
    let open Memo.O in
    let* installed_libs = Lib.DB.installed ctx in
    Lib.DB.find installed_libs pkg >>= function
    | None -> Memo.return ()
    | Some pkg ->
      let info = Lib.info pkg in
      let lib_name = Lib_name.to_string (Lib.name pkg) in
      let archives =
        let archives = (Lib_info.archives info).byte in
        (* Special case for the stdlib because it is not referenced in the
           META *)
        match lib_name with
        | "stdlib" ->
          let archive =
            let stdlib_dir = (Lib.lib_config pkg).stdlib_dir in
            Path.relative stdlib_dir
          in
          archive "stdlib.cma" :: archive "std_exit.cmo" :: archives
        | _ -> archives
      in
      Memo.parallel_iter archives ~f:(fun fn ->
          let name = Path.basename fn in
          let dir = in_build_dir ~sctx ~config [ lib_name ] in
          let in_context =
            { Js_of_ocaml.In_context.flags = Js_of_ocaml.Flags.standard
            ; javascript_files = []
            }
          in
          let src =
            let src_dir = Lib_info.src_dir info in
            Path.relative src_dir name
          in
          let target =
            in_build_dir ~sctx ~config [ lib_name; with_js_ext name ]
          in
          build_cm' sctx ~dir ~in_context ~src ~target
            ~config:(Some (Action_builder.return config))
          >>= Super_context.add_rule sctx ~dir))

let build_exe cc ~loc ~in_context ~src ~(obj_dir : Path.Build.t Obj_dir.t)
    ~(top_sorted_modules : Module.t list Action_builder.t) ~promote
    ~link_time_code_gen =
  let sctx = Compilation_context.super_context cc in
  let dir = Compilation_context.dir cc in
  let { Js_of_ocaml.In_context.javascript_files; flags } = in_context in
  let target = Path.Build.set_extension src ~ext:Js_of_ocaml.Ext.exe in
  let standalone_runtime =
    in_obj_dir ~obj_dir ~config:None
      [ Path.Build.basename
          (Path.Build.set_extension src ~ext:Js_of_ocaml.Ext.runtime)
      ]
  in
  let mode : Rule.Mode.t =
    match promote with
    | None -> Standard
    | Some p -> Promote p
  in
  let open Memo.O in
  let* cmode = Super_context.js_of_ocaml_compilation_mode sctx ~dir in
  match (cmode : Js_of_ocaml.Compilation_mode.t) with
  | Separate_compilation ->
    standalone_runtime_rule cc ~javascript_files ~target:standalone_runtime
      ~flags
    >>= Super_context.add_rule ~loc sctx ~dir
    >>> link_rule cc ~runtime:standalone_runtime ~target ~obj_dir
          top_sorted_modules ~flags ~link_time_code_gen
    >>= Super_context.add_rule sctx ~loc ~dir ~mode
  | Whole_program ->
    exe_rule cc ~javascript_files ~src ~target ~flags
    >>= Super_context.add_rule sctx ~loc ~dir ~mode

let runner = "node"
