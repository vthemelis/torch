open! Base

type t = { apply : Tensor.t -> Tensor.t }
type t_with_training = { apply_with_training : Tensor.t -> is_training:bool -> Tensor.t }

let with_training t =
  let apply_with_training xs ~is_training:_ = t.apply xs in
  { apply_with_training }
;;

type activation =
  | Relu
  | Softmax
  | Log_softmax
  | Tanh
  | Leaky_relu
  | Sigmoid

let kaiming_uniform vs ~name ~shape ~a =
  let fan_in =
    match shape with
    | [] | [ _ ] -> failwith "unexpected tensor shape"
    | _fan_out :: fan_in :: others ->
      let others = List.fold others ~init:1 ~f:( * ) in
      fan_in * others
  in
  let std = Float.sqrt (2. /. ((1. +. (a *. a)) *. Float.of_int fan_in)) in
  let bound = Float.sqrt 3. *. std in
  Var_store.new_var vs ~shape ~init:(Uniform (-.bound, bound)) ~name
;;

let apply ?activation ys =
  match activation with
  | Some Relu -> Tensor.relu ys
  | Some Softmax -> Tensor.softmax ys ~dim:(-1) ~dtype:(T Float)
  | Some Log_softmax -> Tensor.log_softmax ys ~dim:(-1) ~dtype:(T Float)
  | Some Tanh -> Tensor.tanh ys
  | Some Sigmoid -> Tensor.sigmoid ys
  | Some Leaky_relu -> Tensor.leaky_relu ys
  | None -> ys
;;

let linear vs ?activation ?(use_bias = true) ?w_init ~input_dim output_dim =
  let w =
    let shape = [ output_dim; input_dim ] in
    match w_init with
    | None -> kaiming_uniform vs ~shape ~a:(Float.sqrt 5.) ~name:"weight"
    | Some init -> Var_store.new_var vs ~shape ~init ~name:"weight"
  in
  let apply =
    if use_bias
    then (
      let bound = 1.0 /. Float.sqrt (Float.of_int input_dim) in
      let b =
        Var_store.new_var
          vs
          ~shape:[ output_dim ]
          ~init:(Uniform (-.bound, bound))
          ~name:"bias"
      in
      fun xs -> Tensor.(mm xs (tr w) + b) |> apply ?activation)
    else fun xs -> Tensor.(mm xs (tr w)) |> apply ?activation
  in
  { apply }
;;

let conv2d
      vs
      ~ksize:(k1, k2)
      ~stride
      ?activation
      ?(use_bias = true)
      ?w_init
      ?(padding = 0, 0)
      ?(groups = 1)
      ~input_dim
      output_dim
  =
  let w =
    let shape = [ output_dim; input_dim / groups; k1; k2 ] in
    match w_init with
    | None -> kaiming_uniform vs ~shape ~a:(Float.sqrt 5.) ~name:"weight"
    | Some init -> Var_store.new_var vs ~shape ~init ~name:"weight"
  in
  let b =
    if use_bias
    then Some (Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros ~name:"bias")
    else None
  in
  let apply xs = Tensor.conv2d xs w b ~padding ~stride ~groups |> apply ?activation in
  { apply }
;;

let conv2d_
      vs
      ~ksize
      ~stride
      ?activation
      ?use_bias
      ?w_init
      ?(padding = 0)
      ?groups
      ~input_dim
      output_dim
  =
  conv2d
    vs
    ~ksize:(ksize, ksize)
    ~stride:(stride, stride)
    ?use_bias
    ?activation
    ?w_init
    ~padding:(padding, padding)
    ?groups
    ~input_dim
    output_dim
;;

let conv_transpose2d
      vs
      ~ksize:(k1, k2)
      ~stride
      ?activation
      ?(use_bias = true)
      ?(w_init = Var_store.Init.Normal { mean = 0.; stdev = 0.1 })
      ?(padding = 0, 0)
      ?(output_padding = 0, 0)
      ?(groups = 1)
      ~input_dim
      output_dim
  =
  let w =
    Var_store.new_var
      vs
      ~shape:[ input_dim; output_dim / groups; k1; k2 ]
      ~init:w_init
      ~name:"weight"
  in
  let apply =
    let b =
      if use_bias
      then Some (Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros ~name:"bias")
      else None
    in
    fun xs ->
      Tensor.conv_transpose2d xs w b ~output_padding ~padding ~stride ~groups
      |> apply ?activation
  in
  { apply }
;;

let conv_transpose2d_
      vs
      ~ksize
      ~stride
      ?activation
      ?use_bias
      ?w_init
      ?(padding = 0)
      ?(output_padding = 0)
      ?groups
      ~input_dim
      output_dim
  =
  conv_transpose2d
    vs
    ~ksize:(ksize, ksize)
    ~stride:(stride, stride)
    ?activation
    ?use_bias
    ?w_init
    ~padding:(padding, padding)
    ~output_padding:(output_padding, output_padding)
    ?groups
    ~input_dim
    output_dim
;;

let batch_norm2d
      vs
      ?(w_init = Var_store.Init.Uniform (0., 1.))
      ?(cudnn_enabled = true)
      ?(eps = 1e-5)
      ?(momentum = 0.1)
      output_dim
  =
  let w = Var_store.new_var vs ~shape:[ output_dim ] ~init:w_init ~name:"weight" in
  let b = Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros ~name:"bias" in
  let running_mean =
    Var_store.new_var
      vs
      ~trainable:false
      ~shape:[ output_dim ]
      ~init:Zeros
      ~name:"running_mean"
  in
  let running_var =
    Var_store.new_var
      vs
      ~trainable:false
      ~shape:[ output_dim ]
      ~init:Ones
      ~name:"running_var"
  in
  let apply_with_training xs ~is_training =
    Tensor.batch_norm
      xs
      ~weight:(Some w)
      ~bias:(Some b)
      ~running_mean:(Some running_mean)
      ~running_var:(Some running_var)
      ~training:is_training
      ~momentum
      ~eps
      ~cudnn_enabled
  in
  { apply_with_training }
;;

let layer_norm vs ?(cudnn_enable = true) ?(eps = 1e-5) dim =
  let weight = Var_store.new_var vs ~name:"weight" ~shape:[ dim ] ~init:Ones in
  let bias = Var_store.new_var vs ~name:"bias" ~shape:[ dim ] ~init:Zeros in
  let apply xs =
    Tensor.layer_norm
      xs
      ~normalized_shape:[ dim ]
      ~weight:(Some weight)
      ~bias:(Some bias)
      ~eps
      ~cudnn_enable
  in
  { apply }
;;

let forward t xs = t.apply xs

let forward_ t_with_training xs ~is_training =
  t_with_training.apply_with_training xs ~is_training
;;

let id = { apply = Fn.id }
let id_ = { apply_with_training = (fun xs ~is_training:_ -> xs) }
let of_fn apply = { apply }
let of_fn_ apply_with_training = { apply_with_training }

let sequential t_list =
  let apply xs = List.fold t_list ~init:xs ~f:(fun acc t -> t.apply acc) in
  { apply }
;;

let sequential_ t_list =
  let apply_with_training xs ~is_training =
    List.fold t_list ~init:xs ~f:(fun acc t -> t.apply_with_training acc ~is_training)
  in
  { apply_with_training }
;;

module Lstm = struct
  type t =
    { w_ih : Tensor.t
    ; w_hh : Tensor.t
    ; b_ih : Tensor.t
    ; b_hh : Tensor.t
    ; hidden_size : int
    ; device : Device.t
    }

  type state = [ `h_c of Tensor.t * Tensor.t ]

  let create vs ~input_dim ~hidden_size =
    let gate_size = 4 * hidden_size in
    let w_ih =
      kaiming_uniform vs ~shape:[ gate_size; input_dim ] ~a:(Float.sqrt 5.) ~name:"w_ih"
    in
    let w_hh =
      kaiming_uniform vs ~shape:[ gate_size; hidden_size ] ~a:(Float.sqrt 5.) ~name:"w_hh"
    in
    let b_ih = Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros ~name:"b_ih" in
    let b_hh = Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros ~name:"b_hh" in
    if Device.is_cuda (Var_store.device vs) && Cuda.cudnn_is_available ()
    then
      Tensor.no_grad (fun () ->
        Tensor._cudnn_rnn_flatten_weight
          ~weight_arr:[ w_ih; w_hh; b_ih; b_hh ]
          ~weight_stride0:4
          ~input_size:input_dim
          ~mode:2 (* 2 for LSTM, see rnn.cpp in pytorch *)
          ~hidden_size
          ~num_layers:1
          ~batch_first:true
          ~bidirectional:false
          ~proj_size:0
        |> (ignore : Tensor.t -> unit));
    { w_ih; w_hh; b_ih; b_hh; hidden_size; device = Var_store.device vs }
  ;;

  let zero_state t ~batch_size =
    let zeros = Tensor.zeros [ batch_size; t.hidden_size ] ~device:t.device in
    `h_c (zeros, zeros)
  ;;

  let step t (`h_c (h, c)) input_ =
    let h, c =
      Tensor.lstm_cell
        input_
        ~hx:[ h; c ]
        ~w_ih:t.w_ih
        ~w_hh:t.w_hh
        ~b_ih:(Some t.b_ih)
        ~b_hh:(Some t.b_hh)
    in
    `h_c (h, c)
  ;;

  let seq t input_ ~is_training =
    let batch_size = Tensor.shape input_ |> List.hd_exn in
    let h = Tensor.zeros [ 1; batch_size; t.hidden_size ] ~device:t.device in
    let c = Tensor.zeros [ 1; batch_size; t.hidden_size ] ~device:t.device in
    let output, h, c =
      Tensor.lstm
        input_
        ~hx:[ h; c ]
        ~params:[ t.w_ih; t.w_hh; t.b_ih; t.b_hh ]
        ~has_biases:true
        ~num_layers:1
        ~dropout:0.
        ~train:is_training
        ~bidirectional:false
        ~batch_first:true
    in
    output, `h_c (h, c)
  ;;
end

module Gru = struct
  type t =
    { w_ih : Tensor.t
    ; w_hh : Tensor.t
    ; b_ih : Tensor.t
    ; b_hh : Tensor.t
    ; hidden_size : int
    ; device : Device.t
    }

  type state = [ `state of Tensor.t ]

  let create vs ~input_dim ~hidden_size =
    let gate_size = 3 * hidden_size in
    let w_ih =
      kaiming_uniform vs ~shape:[ gate_size; input_dim ] ~a:(Float.sqrt 5.) ~name:"w_ih"
    in
    let w_hh =
      kaiming_uniform vs ~shape:[ gate_size; hidden_size ] ~a:(Float.sqrt 5.) ~name:"w_hh"
    in
    let b_ih = Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros ~name:"b_ih" in
    let b_hh = Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros ~name:"b_hh" in
    { w_ih; w_hh; b_ih; b_hh; hidden_size; device = Var_store.device vs }
  ;;

  let zero_state t ~batch_size =
    let state = Tensor.zeros [ batch_size; t.hidden_size ] ~device:t.device in
    `state state
  ;;

  let step t (`state hx) input_ =
    let out =
      Tensor.gru_cell input_ ~hx ~w_ih:t.w_ih ~w_hh:t.w_hh ~b_ih:None ~b_hh:None
    in
    `state out
  ;;

  let seq t input_ ~is_training =
    let batch_size = Tensor.shape input_ |> List.hd_exn in
    let hx = Tensor.zeros [ 1; batch_size; t.hidden_size ] ~device:t.device in
    let out, state =
      Tensor.gru
        input_
        ~hx
        ~params:[ t.w_ih; t.w_hh; t.b_ih; t.b_hh ]
        ~has_biases:true
        ~num_layers:1
        ~dropout:0.
        ~train:is_training
        ~bidirectional:false
        ~batch_first:true
    in
    out, `state state
  ;;
end

let embeddings
      ?(sparse = false)
      ?(scale_grad_by_freq = false)
      vs
      ~num_embeddings
      ~embedding_dim
  =
  let weight =
    Var_store.new_var
      vs
      ~shape:[ num_embeddings; embedding_dim ]
      ~init:(Normal { mean = 0.; stdev = 1. })
      ~name:"weight"
  in
  let apply indices =
    Tensor.embedding ~weight ~indices ~padding_idx:(-1) ~sparse ~scale_grad_by_freq
  in
  { apply }
;;
