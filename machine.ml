
type memory = (Int64.t, (Int64.t array)) Hashtbl.t
type registers = Int64.t array
type perf = { 
    bp : Predictors.predictor;
    rp : Predictors.predictor;
    l2 : Cache.cache;
    i : Cache.cache;
    d : Cache.cache;
    fetch_start : Resource.resource;
    fetch_decode_q : Resource.resource;
    rob : Resource.resource;
    alu : Resource.resource;
    agen : Resource.resource;
    dcache : Resource.resource;
    retire : Resource.resource;
    reg_ready : int array;
    dec_lat : int
  }

type state = {
    mutable show : bool;
    mutable running : bool;
    mutable p_pos : int;
    mutable disas : Ast.line option;
    mutable tracefile : out_channel option;
    mutable ip : Int64.t;
    regs : registers;
    mem : Memory.t;
  }

let create () = 
  let machine = { 
      show = false; 
      running = false;
      p_pos = 0; 
      tracefile = None;
      disas = None;
      ip = Int64.zero; 
      regs = Array.make 16 Int64.zero; 
      mem = Memory.create () 
    } in
  machine

let set_show state = state.show <- true

let set_tracefile state channel = state.tracefile <- Some channel

exception Unknown_digit of char

let hex_to_int c =
  match c with
  | '0' -> 0
  | '1' -> 1
  | '2' -> 2
  | '3' -> 3
  | '4' -> 4
  | '5' -> 5
  | '6' -> 6
  | '7' -> 7
  | '8' -> 8
  | '9' -> 9
  | 'A' -> 10
  | 'B' -> 11
  | 'C' -> 12
  | 'D' -> 13
  | 'E' -> 14
  | 'F' -> 15
  | 'a' -> 10
  | 'b' -> 11
  | 'c' -> 12
  | 'd' -> 13
  | 'e' -> 14
  | 'f' -> 15
  | _  -> 0



let init (hex : (int * string) list) : state = 
  let s = create () in
  let write_line (addr,b) = begin
    for entry = 0 to ((String.length b) / 2) - 1 do
      let digit = hex_to_int b.[entry * 2] * 16 + hex_to_int b.[entry * 2 + 1] in
      Memory.write_byte s.mem (Int64.of_int (addr + entry)) digit;
    done
  end
  in
  List.iter write_line hex;
  s

let next_ip state = state.ip <- Int64.succ state.ip

let _fetch state =
  let v = Memory.read_byte state.mem state.ip in
  next_ip state;
  v

let fetch state =
  let byte = _fetch state in
  if state.show then Printf.printf "%02x " byte;
  state.p_pos <- 3 + state.p_pos;
  byte

let fetch_first state =
  let first_byte = _fetch state in
  if state.show then Printf.printf "\n%08x : %02x " ((Int64.to_int state.ip) - 1) first_byte;
  state.p_pos <- 3;
  first_byte

let fetch_imm state =
  let a = _fetch state in
  let b = _fetch state in
  let c = _fetch state in
  let d = _fetch state in
  let imm =(((((d lsl 8) + c) lsl 8) + b) lsl 8) + a in
  if state.show then Printf.printf "%08x " imm;
  state.p_pos <- 9 + state.p_pos;
  imm

let imm_to_qimm imm =
  if (imm lsr 31) == 0 then
    Int64.of_int imm
  else (* negative *)
    let hi = Int64.shift_left (Int64.of_int 0xFFFFFFFF) 32 in
    let lo = Int64.of_int imm in
    Int64.logor hi lo

exception UnknownInstructionAt of int
exception UnimplementedCondition of int
exception UnknownPort of int

let split_byte byte = (byte lsr 4, byte land 0x0F)

let comp a b = Int64.compare a b

let eval_condition cond b a =
  (* Printf.printf "{ %d %x %x }" cond (Int64.to_int a) (Int64.to_int b); *)
  match cond with
  | 0 -> a = b
  | 1 -> a <> b
  | 4 -> a < b
  | 5 -> a <= b
  | 6 -> a > b
  | 7 -> a >= b
  | 8 -> begin (* unsigned above  (a > b) *)
      if a < Int64.zero && b >= Int64.zero then true
      else if a >= Int64.zero && b < Int64.zero then false
      else a > b
    end
  | 9 -> begin (* unsigned above or equal (a >= b) *)
      if a < Int64.zero && b >= Int64.zero then true
      else if a >= Int64.zero && b < Int64.zero then false
      else a >= b
    end
  | 10 -> begin (* unsigned below  (a < b) *)
      if a < Int64.zero && b >= Int64.zero then false
      else if a >= Int64.zero && b < Int64.zero then true
      else a < b
    end
  | 11 -> begin (* unsigned below or equal (a <= b) *)
      if a < Int64.zero && b >= Int64.zero then false
      else if a >= Int64.zero && b < Int64.zero then true
      else a <= b
    end
  | _ -> raise (UnimplementedCondition cond)

let disas_cond cond =
  let open Ast in
  match cond with
  | 0 -> E
  | 1 -> NE
  | 4 -> L
  | 5 -> LE
  | 6 -> G
  | 7 -> GE
  | 8 -> A
  | 9 -> AE
  | 10 -> B
  | 11 -> BE
  | _ -> raise (UnimplementedCondition cond)

let align_output state =
  while state.p_pos < 30 do
    Printf.printf " ";
    state.p_pos <- 1 + state.p_pos
  done;
  match state.disas with
  | Some(d) -> Printf.printf "%-40s" (Printer.print_insn d)
  | None -> ()

let reg_name reg =
  match reg with
  | 0 -> "%rax"
  | 1 -> "%rbx"
  | 2 -> "%rcx"
  | 3 -> "%rdx"
  | 4 -> "%rbp"
  | 5 -> "%rsi"
  | 6 -> "%rdi"
  | 7 -> "%rsp"
  | _ -> Printf.sprintf "%%r%-2d" reg

let log_ip state =
  match state.tracefile with
  | Some(channel) -> Printf.fprintf channel "P %x %Lx\n" 0 state.ip
  | None -> ()

let wr_reg state reg value =
  if state.show then begin
      align_output state;
      Printf.printf "%s <- 0x%Lx" (reg_name reg) value;
    end;
  begin
    match state.tracefile with
    | Some(channel) -> Printf.fprintf channel "R %x %Lx\n" reg value
    | None -> ()
  end;
  state.regs.(reg) <- value

let is_io_area addr = (Int64.shift_right addr 28) = Int64.one

let perform_output port value = 
  if port = 2 then Printf.printf "%016Lx " value
  else raise (UnknownPort port)

let perform_input port =
  if port = 0 then Int64.of_int (read_int ())
  else if port = 1 then Random.int64 Int64.max_int
  else raise (UnknownPort port)

let rd_mem state (addr : Int64.t) =
  if is_io_area addr then
    let port = (Int64.to_int addr) land 0x0ff in
    let value = perform_input port in
    begin
      match state.tracefile with
      | Some(channel) -> Printf.fprintf channel "I %Lx %Lx\n" addr value
      | None -> ()
    end;
    value
  else
    Memory.read_quad state.mem addr

let wr_mem state addr value =
  if is_io_area addr then begin
    let port = (Int64.to_int addr) land 0x0ff in
    perform_output port value;
    match state.tracefile with
    | Some(channel) -> Printf.fprintf channel "O %Lx %Lx\n" addr value
    | None -> ()
  end else begin
    if state.show then begin
      align_output state;
      Printf.printf "Memory[ 0x%Lx ] <- 0x%Lx" addr value
    end;
    begin
      match state.tracefile with
      | Some(channel) -> Printf.fprintf channel "M %Lx %Lx\n" addr value
      | None -> ()
    end;
    Memory.write_quad state.mem addr value
  end

let set_ip state ip =
  if state.show then Printf.printf "Starting execution from address 0x%X\n" ip;
  state.ip <- Int64.of_int ip

let fetch_from_offs state offs =
  Memory.read_byte state.mem (Int64.add state.ip (Int64.of_int offs)) 

let fetch_imm_from_offs state offs =
  let a = fetch_from_offs state offs in
  let b = fetch_from_offs state (offs + 1) in
  let c = fetch_from_offs state (offs + 2) in
  let d = fetch_from_offs state (offs + 3) in
  let imm =(((((d lsl 8) + c) lsl 8) + b) lsl 8) + a in
  imm

let disas_reg r =
  match r with
  | 0 -> "%rax"
  | 1 -> "%rbx"
  | 2 -> "%rcx"
  | 3 -> "%rdx"
  | 4 -> "%rbp"
  | 5 -> "%rsi"
  | 6 -> "%rdi"
  | 7 -> "%rsp"
  | _ -> Printf.sprintf "%%r%d" r


let disas_sh sh =
  match sh with
  | 0 -> "1"
  | 1 -> "2"
  | 2 -> "4"
  | 3 -> "8"
  | _ -> "?"

let disas_imm imm = 
  let i : Int32.t = Int32.of_int imm in
  if i < Int32.zero then Int32.to_string i
  else Int32.to_string i

let disas_mem imm = Printf.sprintf "0x%x" imm

let disas_inst state =
  let first_byte = fetch_from_offs state 0 in
  let (hi,lo) = split_byte first_byte in
  let second_byte = fetch_from_offs state 1 in
  let (rd,rs) = split_byte second_byte in
  match hi,lo with
  | 0,0 -> Ast.Ctl1(RET,Reg(disas_reg rs))
  | 0,1 -> Ast.Ctl0(SYSCALL)
  | 1,0 -> Ast.Alu2(ADD,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,1 -> Ast.Alu2(SUB,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,2 -> Ast.Alu2(AND,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,3 -> Ast.Alu2(OR,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,4 -> Ast.Alu2(XOR,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,5 -> Ast.Alu2(MUL,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,6 -> Ast.Alu2(SAR,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,7 -> Ast.Alu2(SAL,Reg(disas_reg rs), Reg(disas_reg rd))
  | 1,8 -> Ast.Alu2(SHR,Reg(disas_reg rs), Reg(disas_reg rd))
  | 2,1 -> Ast.Move2(MOV,Reg(disas_reg rs), Reg(disas_reg rd))
  | 3,1 -> Ast.Move2(MOV,EaS(disas_reg rs), Reg(disas_reg rd))
  | 3,9 -> Ast.Move2(MOV,Reg(disas_reg rd), EaS(disas_reg rs))
  | 4,_ | 5,_ | 6,_ | 7,_ -> begin (* instructions with 2 bytes + 1 immediate *)
      let imm = fetch_imm_from_offs state 2 in
      match hi,lo with
      | 4,0xE -> Ast.Ctl2(CALL,EaD(disas_mem imm),Reg(disas_reg rd))
      | 4,0xF -> Ast.Ctl1(JMP,EaD(disas_mem imm))
      | 4,_ -> Ast.Ctl3(CBcc(disas_cond lo),Reg(disas_reg rd),Reg(disas_reg rs),EaD(disas_mem imm));
      | 5,0 -> Ast.Alu2(ADD,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,1 -> Ast.Alu2(SUB,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,2 -> Ast.Alu2(AND,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,3 -> Ast.Alu2(OR,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,4 -> Ast.Alu2(XOR,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,5 -> Ast.Alu2(MUL,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,6 -> Ast.Alu2(SAR,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,7 -> Ast.Alu2(SAL,Imm(disas_imm imm),Reg(disas_reg rd))
      | 5,8 -> Ast.Alu2(SHR,Imm(disas_imm imm),Reg(disas_reg rd))
      | 6,4 -> Ast.Move2(MOV,Imm(disas_imm imm),Reg(disas_reg rd))
      | 7,5 -> Ast.Move2(MOV,EaDS(disas_imm imm,disas_reg rs),Reg(disas_reg rd))
      | 7,0xD ->Ast.Move2(MOV,Reg(disas_reg rd), EaDS(disas_imm imm,disas_reg rs))
      | _ -> raise (UnknownInstructionAt (Int64.to_int state.ip))
    end
  | 8,_ | 9,_ | 10,_ | 11,_ -> begin (* leaq *)
      let has_third_byte = hi = 9 || hi = 11 in
      let has_imm = hi = 10 || hi = 11 in
      let imm_offs = if has_third_byte then 3 else 2 in
      let (rz,sh) = if has_third_byte then split_byte (fetch_from_offs state 2) else 0,0 in
      let imm = if has_imm then fetch_imm_from_offs state imm_offs else 0 in
      match lo with
      | 1 -> Ast.Alu2(LEA,EaS(disas_reg rs),Reg(disas_reg rd))
      | 2 -> Ast.Alu2(LEA,EaZ(disas_reg rz,disas_sh sh),Reg(disas_reg rd))
      | 3 -> Ast.Alu2(LEA,EaZS(disas_reg rs,disas_reg rz,disas_sh sh),Reg(disas_reg rd))
      | 4 -> Ast.Alu2(LEA,EaD(disas_mem imm),Reg(disas_reg rd))
      | 5 -> Ast.Alu2(LEA,EaDS(disas_imm imm, disas_reg rs),Reg(disas_reg rd))
      | 6 -> Ast.Alu2(LEA,EaDZ(disas_imm imm, disas_reg rz,disas_sh sh),Reg(disas_reg rd))
      | 7 -> Ast.Alu2(LEA,EaDZS(disas_imm imm, disas_reg rs,disas_reg rz,disas_sh sh),Reg(disas_reg rd))
      | _ -> raise (UnknownInstructionAt (Int64.to_int state.ip))
    end
  | 15,_ -> begin (* cbcc with both imm and target *)
      let imm = fetch_imm_from_offs state 2 in
      let a_imm = fetch_imm_from_offs state 6 in
      Ast.Ctl3(CBcc(disas_cond lo),Imm(disas_imm imm),Reg(disas_reg rd),EaD(disas_mem a_imm))
    end
  | _ -> raise (UnknownInstructionAt (Int64.to_int state.ip))

let terminate_output state = if state.show then align_output state

let model_fetch_decode perf state =
  let start = Resource.acquire perf.fetch_start 0 in
  let start = Resource.acquire perf.fetch_decode_q start in
  let got_inst = Cache.cache_read perf.i state.ip start in
  let rob_entry = Resource.acquire perf.rob (got_inst + perf.dec_lat) in
  Resource.use perf.fetch_start start (start + 1);
  Resource.use perf.fetch_decode_q start rob_entry;
  rob_entry
 (* FIXME if in-order, we need to wait for the actual execution resource to be allocated *)

let model_return perf state rs =
  let rob_entry = model_fetch_decode perf state in
  let ready = max perf.reg_ready.(rs) rob_entry in
  let exec_start = Resource.acquire perf.alu ready in
  let time_retire = Resource.acquire perf.retire (exec_start + 2) in
  let addr = state.regs.(rs) in
  let predicted = Predictors.predict_return perf.rp (Int64.to_int addr) in
  if predicted then
    Resource.use_all perf.fetch_start (Resource.get_earliest perf.fetch_start + 1)
  else
    Resource.use_all perf.fetch_start (exec_start + 1);
  Resource.use perf.alu exec_start (exec_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire

let model_call perf state rd addr =
  let rob_entry = model_fetch_decode perf state in
  let exec_start = Resource.acquire perf.alu rob_entry in
  let time_retire = Resource.acquire perf.retire (exec_start + 2) in
  Predictors.note_call perf.rp (Int64.to_int addr);
  Resource.use_all perf.fetch_start (Resource.get_earliest perf.fetch_start + 1);
  Resource.use perf.alu exec_start (exec_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire;
  perf.reg_ready.(rd) <- exec_start + 1

let model_jmp perf state =
  let rob_entry = model_fetch_decode perf state in
  let exec_start = Resource.acquire perf.alu rob_entry in
  let time_retire = Resource.acquire perf.retire (exec_start + 2) in
  Resource.use_all perf.fetch_start (Resource.get_earliest perf.fetch_start + 1);
  Resource.use perf.alu exec_start (exec_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire

let model_nop perf state =
  let rob_entry = model_fetch_decode perf state in
  let exec_start = Resource.acquire perf.alu rob_entry in
  let time_retire = Resource.acquire perf.retire (exec_start + 2) in
  Resource.use perf.alu exec_start (exec_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire

let model_cond_branch perf state from_ip to_ip taken ops_ready =
  let rob_entry = model_fetch_decode perf state in
  let ready = max rob_entry ops_ready in
  let exec_start = Resource.acquire perf.alu ready in
  let exec_done = exec_start + 1 in
  let time_retire = Resource.acquire perf.retire (exec_done + 1) in
  let predicted = Predictors.predict_and_train perf.bp from_ip to_ip taken in
  if not predicted then
    Resource.use_all perf.fetch_start exec_done
  else if taken then
    Resource.use_all perf.fetch_start (Resource.get_earliest perf.fetch_start + 1);
  Resource.use perf.alu exec_start (exec_done);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire

let model_compute perf state rd ops_ready latency =
  let rob_entry = model_fetch_decode perf state in
  let ready = max rob_entry ops_ready in
  let exec_start = Resource.acquire perf.alu ready in
  let exec_done = exec_start + latency in
  let time_retire = Resource.acquire perf.retire (exec_done + 1) in
  Resource.use perf.alu exec_start (exec_done);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire;
  perf.reg_ready.(rd) <- exec_done

let model_mov_imm perf state rd = model_compute perf state rd 0 1
let model_leaq perf state rd ops_ready = model_compute perf state rd ops_ready 1
let model_mov_reg perf state rd rs = model_compute perf state rd (perf.reg_ready.(rs)) 1
let model_alu_imm perf state rd = model_compute perf state rd (perf.reg_ready.(rd)) 1
let model_mul_imm perf state rd = model_compute perf state rd (perf.reg_ready.(rd)) 3
let model_alu_reg perf state rd rs = model_compute perf state rd (max perf.reg_ready.(rd) perf.reg_ready.(rs)) 1
let model_mul_reg perf state rd rs = model_compute perf state rd (max perf.reg_ready.(rd) perf.reg_ready.(rs)) 3

let model_store perf state rd rs addr =
  let ops_ready = perf.reg_ready.(rs) in
  let rob_entry = model_fetch_decode perf state in
  let ready = max rob_entry ops_ready in
  let agen_start = Resource.acquire perf.agen ready in
  let agen_done = agen_start + 1 in
  let store_data_ready = max agen_done perf.reg_ready.(rd) in
  let access_start = Resource.acquire perf.dcache store_data_ready in
  let _ = Cache.cache_write perf.d addr access_start in
  let access_done = access_start + 1 in
  let time_retire = Resource.acquire perf.retire (access_done + 1) in
  Resource.use perf.agen agen_start agen_done;
  Resource.use perf.dcache access_start (access_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire

let model_load perf state rd rs addr =
  let ops_ready = perf.reg_ready.(rs) in
  let rob_entry = model_fetch_decode perf state in
  let ready = max rob_entry ops_ready in
  let agen_start = Resource.acquire perf.agen ready in
  let agen_done = agen_start + 1 in
  let access_start = Resource.acquire perf.dcache agen_done in
  let data_ready = Cache.cache_read perf.d addr access_start in
  let access_done = access_start + 1 in
  let time_retire = Resource.acquire perf.retire (access_done + 1) in
  Resource.use perf.agen agen_start agen_done;
  Resource.use perf.dcache access_start (access_start + 1);
  Resource.use perf.retire time_retire (time_retire + 1);
  Resource.use perf.rob rob_entry time_retire;
  perf.reg_ready.(rd) <- data_ready



let model_load_imm perf state rd rs = model_load perf state rd perf.reg_ready.(rs)

let run_inst perf state =
  log_ip state;
  if state.show then state.disas <- Some(disas_inst state);
  let first_byte = fetch_first state in
  let (hi,lo) = split_byte first_byte in
  let second_byte = fetch state in
  let (rd,rs) = split_byte second_byte in
  match hi,lo with
  | 0,0 -> begin
      terminate_output state;
      let ret_addr = state.regs.(rs) in (* return instruction *)
      model_return perf state rs;
      state.ip <- ret_addr;
      if ret_addr <= Int64.zero then begin
          log_ip state; (* final IP value should be added to trace *)
          state.running <- false;
          if state.show then Printf.printf "\nTerminating. Return to address %Lx\n" ret_addr
        end
    end
  | 0,1 -> begin
             if state.regs.(0) = Int64.zero then begin
               model_alu_imm perf state 0;
               wr_reg state 0 (perform_input 0)
             end else if state.regs.(0) = Int64.one then begin
               model_alu_imm perf state 0;
               wr_reg state 0 (perform_input 1)
             end else if state.regs.(0) = Int64.of_int 2 then begin
               model_nop perf state; terminate_output state; perform_output 0 state.regs.(1)
             end else
               raise (UnknownInstructionAt (Int64.to_int state.ip))
           end
  | 1,0 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.add state.regs.(rd) state.regs.(rs))
  | 1,1 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.sub state.regs.(rd) state.regs.(rs))
  | 1,2 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.logand state.regs.(rd) state.regs.(rs))
  | 1,3 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.logor state.regs.(rd) state.regs.(rs))
  | 1,4 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.logxor state.regs.(rd) state.regs.(rs))
  | 1,5 -> model_mul_reg perf state rd rs; wr_reg state rd (Int64.mul state.regs.(rd) state.regs.(rs))
  | 1,6 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.shift_right state.regs.(rd) (Int64.to_int state.regs.(rs)))
  | 1,7 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.shift_left state.regs.(rd) (Int64.to_int state.regs.(rs)))
  | 1,8 -> model_alu_reg perf state rd rs; wr_reg state rd (Int64.shift_right_logical state.regs.(rd) (Int64.to_int state.regs.(rs)))
  | 2,1 -> model_mov_reg perf state rs rd; wr_reg state rd state.regs.(rs)
  | 3,1 -> begin
      model_load perf state rd rs state.regs.(rs);
      wr_reg state rd (rd_mem state state.regs.(rs))
    end
  | 3,9 -> begin
      model_store perf state rd rs state.regs.(rs);
      wr_mem state state.regs.(rs) state.regs.(rd)
    end
  | 4,_ | 5,_ | 6,_ | 7,_ -> begin (* instructions with 2 bytes + 1 immediate *)
      let imm = fetch_imm state in
      let qimm = imm_to_qimm imm in
      match hi,lo with
      | 4,0xE -> begin
          wr_reg state rd state.ip; 
          model_call perf state rd state.ip;
          state.ip <- qimm (* call *)
        end
      | 4,0xF -> begin
          terminate_output state; 
          model_jmp perf state;
          state.ip <- qimm (* jmp *)
        end
      | 4,_ -> terminate_output state;
               let taken = eval_condition lo state.regs.(rd) state.regs.(rs) in
               let ops_ready = max perf.reg_ready.(rd) perf.reg_ready.(rs) in
               model_cond_branch perf state (Int64.to_int state.ip) imm taken ops_ready;
               if taken then state.ip <- qimm
      | 5,0 -> model_alu_imm perf state rd; wr_reg state rd (Int64.add state.regs.(rd) qimm)
      | 5,1 -> model_alu_imm perf state rd; wr_reg state rd (Int64.sub state.regs.(rd) qimm)
      | 5,2 -> model_alu_imm perf state rd; wr_reg state rd (Int64.logand state.regs.(rd) qimm)
      | 5,3 -> model_alu_imm perf state rd; wr_reg state rd (Int64.logor state.regs.(rd) qimm)
      | 5,4 -> model_alu_imm perf state rd; wr_reg state rd (Int64.logxor state.regs.(rd) qimm)
      | 5,5 -> model_mul_imm perf state rd; wr_reg state rd (Int64.mul state.regs.(rd) qimm)
      | 5,6 -> model_alu_imm perf state rd; wr_reg state rd (Int64.shift_right state.regs.(rd) imm)
      | 5,7 -> model_alu_imm perf state rd; wr_reg state rd (Int64.shift_left state.regs.(rd) imm)
      | 5,8 -> model_alu_imm perf state rd; wr_reg state rd (Int64.shift_right_logical state.regs.(rd) imm)
      | 6,4 -> model_mov_imm perf state rd; wr_reg state rd qimm
      | 7,5 -> begin
          let a = Int64.add qimm state.regs.(rs) in
          model_load perf state rd rs a;
          wr_reg state rd (rd_mem state a)
        end
      | 7,0xD -> begin
          let a = Int64.add qimm state.regs.(rs) in
          model_store perf state rd rs a;
          wr_mem state a state.regs.(rd)
        end
      | _ -> raise (UnknownInstructionAt (Int64.to_int state.ip))
    end
  | 8,_ | 9,_ | 10,_ | 11,_ -> begin (* leaq *)
      let has_third_byte = hi = 9 || hi = 11 in
      let has_imm = hi = 10 || hi = 11 in
      let (rz,sh) = if has_third_byte then split_byte (fetch state) else 0,0 in
      let qimm = if has_imm then imm_to_qimm (fetch_imm state) else Int64.zero in
      let hasS = lo land 1 = 1 in
      let hasZ = lo land 2 = 2 in
      let hasD = lo land 4 = 4 in
      let ea = Int64.add (if hasS then state.regs.(rs) else Int64.zero)
               (Int64.add (if hasZ then Int64.shift_left state.regs.(rz) sh else Int64.zero)
               (if hasD then qimm else Int64.zero))
      in
      let ops_ready = max (if hasS then perf.reg_ready.(rs) else 0) (if hasZ then perf.reg_ready.(rz) else 0) in
      model_leaq perf state rd ops_ready;
      wr_reg state rd ea
    end
  | 15,_ -> begin (* cbcc with both imm and target *)
      let imm = fetch_imm state in
      let qimm = imm_to_qimm imm in
      let a_imm = fetch_imm state in
      let q_a_imm = imm_to_qimm a_imm in
      let taken = eval_condition lo state.regs.(rd) qimm in
      terminate_output state;
      model_cond_branch perf state (Int64.to_int state.ip) imm taken perf.reg_ready.(rd);
      if (taken) then state.ip <- q_a_imm
    end
  | _ -> raise (UnknownInstructionAt (Int64.to_int state.ip))


let run perf state =
  state.running <- true;
  while state.running && state.ip >= Int64.zero do
    run_inst perf state
  done;
  begin
    match state.tracefile with
    | Some(channel) -> close_out channel
    | None -> ()
  end;
  state.tracefile <- None;
  if state.show then Printf.printf "\nSimulation terminated\n"
