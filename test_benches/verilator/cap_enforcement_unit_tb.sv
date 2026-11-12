`timescale 1ns / 1ps
import capability_types::*;

// Configurable LCC interface: immediate HIT or one delayed lookup.
module ceu_lcc_mock (
    input logic clk,
    rst,
    hit_enable,
    input int unsigned response_latency,
    input cap_metadata_t configured_metadata,
    input gct_error_t configured_error,
    local_cap_cache_interface.lcc lcc_if
);
  logic pending;
  int unsigned cycles_left;
  logic [CAP_IDX_W-1:0] saved_idx;
  logic [PID_W-1:0] saved_pid;
  cap_metadata_t saved_metadata;
  gct_error_t saved_error;
  int unsigned lookup_count, flush_count;

  wire complete = pending && cycles_left == 0;
  assign lcc_if.hit = lcc_if.request &&
      ((hit_enable && !pending) || (complete && saved_error == GCT_ERR_NONE));
  assign lcc_if.error = lcc_if.request && complete ? saved_error : GCT_ERR_NONE;
  assign lcc_if.metadata = pending ? saved_metadata : configured_metadata;

  always_ff @(posedge clk) begin
    if (rst) begin
      pending <= 0;
      cycles_left <= 0;
      lookup_count <= 0;
      flush_count <= 0;
    end else begin
      if (lcc_if.flush) begin
        assert (!pending && !lcc_if.request)
        else $fatal(1, "Flush during lookup");
        flush_count <= flush_count + 1;
      end
      if (pending) begin
        assert (lcc_if.request && lcc_if.cap_idx == saved_idx && lcc_if.caller_pid == saved_pid)
        else $fatal(1, "LCC request was changed or dropped");
        if (complete) pending <= 0;
        else cycles_left <= cycles_left - 1;
      end else if (lcc_if.request && !lcc_if.hit) begin
        pending <= 1;
        cycles_left <= response_latency;
        saved_metadata <= configured_metadata;
        saved_error <= configured_error;
        saved_idx <= lcc_if.cap_idx;
        saved_pid <= lcc_if.caller_pid;
        lookup_count <= lookup_count + 1;
      end
    end
  end
endmodule

// Configurable GCT interface: ready/acceptance and one delayed done pulse.
module ceu_gct_mock (
    input logic clk,
    rst,
    ready_enable,
    input int unsigned response_latency,
    input gct_response_t configured_response,
    global_cap_tree_interface.gct gct_if
);
  logic pending;
  int unsigned cycles_left;
  gct_response_t saved_response;
  int unsigned request_count;

  assign gct_if.ready = ready_enable && !pending;
  always_ff @(posedge clk) begin
    if (rst) begin
      pending <= 0;
      cycles_left <= 0;
      gct_if.done <= 0;
      gct_if.response <= '0;
      request_count <= 0;
    end else begin
      gct_if.done <= 0;
      if (gct_if.new_request) begin
        assert (gct_if.ready)
        else $fatal(1, "GCT request without ready");
        pending <= 1;
        cycles_left <= response_latency;
        saved_response <= configured_response;
        request_count <= request_count + 1;
      end else if (pending) begin
        if (cycles_left == 0) begin
          pending <= 0;
          gct_if.done <= 1;
          gct_if.response <= saved_response;
        end else cycles_left <= cycles_left - 1;
      end
    end
  end
endmodule

module tb_cap_enforcement_unit;
  localparam int TIMEOUT = 40;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  cap_enforcement_unit_interface pipeline_if ();
  local_cap_cache_interface lcc_if ();
  global_cap_tree_interface gct_if ();
  logic hit_enable = 1, ready_enable = 1;
  int unsigned lcc_latency = 2, gct_latency = 2;
  cap_metadata_t metadata = '{PID_W'(7), 32'h1000, 32'h10, R_PERM | W_PERM};
  gct_error_t lookup_error = GCT_ERR_NONE;
  gct_response_t gct_response = '0;
  ceu_request_t req = '0, issued_req = '0;
  int unsigned cycles = 0;

  cap_enforcement_unit dut (
      .clk(clk),
      .rst(rst),
      .pipeline_if(pipeline_if),
      .lcc_if(lcc_if),
      .gct_if(gct_if)
  );
  ceu_lcc_mock lcc (
      .clk(clk),
      .rst(rst),
      .hit_enable(hit_enable),
      .response_latency(lcc_latency),
      .configured_metadata(metadata),
      .configured_error(lookup_error),
      .lcc_if(lcc_if)
  );
  ceu_gct_mock gct (
      .clk(clk),
      .rst(rst),
      .ready_enable(ready_enable),
      .response_latency(gct_latency),
      .configured_response(gct_response),
      .gct_if(gct_if)
  );

  // Monitor the gct and lcc interfaces
  always @(posedge clk) begin
    cycles++;
    if (cycles > 3000) $fatal(1, "Global timeout");
    if (!rst) begin
      if (lcc_if.request)
        assert (issued_req.op == CEU_OP_ACCESS &&
                lcc_if.cap_idx == issued_req.access.cap_idx &&
                lcc_if.caller_pid == issued_req.access.caller_pid)
        else $fatal(1, "Incorrect LCC request");
      if (gct_if.new_request)
        assert (issued_req.op == CEU_OP_GCT && gct_if.request === issued_req.gct)
        else $fatal(1, "Incorrect GCT request");
      if (lcc_if.flush)
        assert (issued_req.op == CEU_OP_SYNC)
        else $fatal(1, "Unexpected flush");
    end
  end


  function automatic gct_error_t access_error(input cap_metadata_t cap, input ceu_access_t access);
    logic [ADDR_W:0] access_end;
    logic [ADDR_W:0] cap_end;
    // Calculate upper bounds
    access_end = {1'b0, access.address} + (ADDR_W+1)'(access.access_size);
    cap_end    = {1'b0, cap.base} + {1'b0, cap.size};
    // Ownership
    if (cap.owner_pid != access.caller_pid) return GCT_ERR_OWNER;
    // Bounds
    if (access.address < cap.base || access_end > cap_end || access_end > 33'h1_0000_0000)
      return GCT_ERR_BOUNDS;
    // Permissions
    if (access.is_store ? !cap.permissions[1] : !cap.permissions[0]) return GCT_ERR_PERM;
    return GCT_ERR_NONE;
  endfunction

  task automatic tick();
    @(negedge clk);
    #1;
  endtask

  task automatic start(input ceu_request_t request);
    issued_req = request;
    pipeline_if.request = request;
    pipeline_if.request_valid = 1;
    #1;
  endtask

  task automatic quiet(input int n = 2);
    repeat (n) begin
      tick();
      assert (!pipeline_if.result_valid && !gct_if.new_request && !lcc_if.flush)
      else $fatal(1, "Unexpected response or side effect");
    end
  endtask

  task automatic expect_response(input gct_error_t error, input int child_idx = 0,
                                 input int hold_cycles = 2);
    for (int i = 0; i < TIMEOUT && !pipeline_if.result_valid; i++) tick();
    assert (pipeline_if.result_valid)
    else $fatal(1, "Response timeout");
    repeat (hold_cycles + 1) begin
      assert (pipeline_if.result_valid && pipeline_if.response.error == error &&
              pipeline_if.response.child_idx == CAP_IDX_W'(child_idx))
      else
        $fatal(
            1,
            "Incorrect or unstable response: expected %0d/%0d, got %p",
            error,
            child_idx,
            pipeline_if.response
        );
      tick();
    end
    pipeline_if.result_ack = 1;
    tick();
    pipeline_if.result_ack = 0;
    pipeline_if.request_valid = 0;
    #1;
    quiet();
  endtask

  task automatic access_test(input bit immediate, input gct_error_t expected);
    int unsigned before_count = lcc.lookup_count;
    hit_enable = immediate;
    start(req);
    assert (pipeline_if.result_valid == immediate)
    else $fatal(1, "Unexpected ACCESS HIT/MISS timing");
    if (!immediate) begin
      for (int i = 0; i < TIMEOUT && !lcc_if.hit && lcc_if.error == GCT_ERR_NONE; i++) begin
        assert (!pipeline_if.result_valid)
        else $fatal(1, "Early ACCESS response");
        tick();
      end
      assert (lcc_if.hit || lcc_if.error != GCT_ERR_NONE)
      else $fatal(1, "LCC completion timeout");
      assert (!pipeline_if.result_valid)
      else $fatal(1, "Early ACCESS response");
    end
    expect_response(expected);
    assert (lcc.lookup_count == before_count + (immediate ? 0 : 1))
    else $fatal(1, "Missing/duplicate LCC lookup");
  endtask

  task automatic cancel_access(input int phase, input gct_error_t error = GCT_ERR_NONE);
    int unsigned before_count = lcc.lookup_count;
    hit_enable = 0;
    lookup_error = error;
    lcc_latency = 3;
    pipeline_if.cancel = (phase == 0);
    start(req);
    if (phase != 0) begin
      tick();  // LCC starts the lookup.
      if (phase >= 2) begin
        for (int i = 0; i < TIMEOUT && !lcc_if.hit && lcc_if.error == GCT_ERR_NONE; i++) tick();
        assert (lcc_if.hit || lcc_if.error != GCT_ERR_NONE)
        else $fatal(1, "LCC completion timeout");
      end
      if (phase == 3) begin
        tick();
        assert (pipeline_if.result_valid)
        else $fatal(1, "Missing ACCESS response");
      end
      pipeline_if.cancel = 1;
    end
    #1;
    assert (!pipeline_if.result_valid)
    else $fatal(1, "Cancelled ACCESS returned a result");
    tick();
    pipeline_if.cancel = 0;
    pipeline_if.request_valid = 0;
    quiet(8);
    assert (!lcc.pending && lcc.lookup_count == before_count + (phase == 0 ? 0 : 1))
    else $fatal(1, "Cancelled lookup not drained or duplicated");
    lookup_error = GCT_ERR_NONE;
    access_test(0, access_error(metadata, req.access));
  endtask

  initial begin
    pipeline_if.request_valid = 0;
    pipeline_if.request = '0;
    pipeline_if.cancel = 0;
    pipeline_if.result_ack = 0;
    repeat (3) tick();
    rst = 0;
    quiet();

    req.op = CEU_OP_ACCESS;
    req.access = '{CAP_IDX_W'(19), PID_W'(7), 32'h1000, 4'd1, 1'b0};
    for (int t = 0; t < 12; t++) begin
      metadata   = '{PID_W'(7), 32'h1000, 32'h10, R_PERM | W_PERM};
      req.access = '{CAP_IDX_W'(19), PID_W'(7), 32'h1000, 4'd1, 1'b0};
      case (t)
        1: req.access.address = 32'h100f;
        2: req.access.address = 32'h0fff;
        3: req.access.address = 32'h1010;
        4: begin
          req.access.address = 32'h100c;
          req.access.access_size = 4;
        end
        5: begin
          req.access.address = 32'h100d;
          req.access.access_size = 4;
        end
        6: req.access.caller_pid = 8;
        7: metadata.permissions = W_PERM;
        8: begin
          req.access.is_store  = 1;
          metadata.permissions = R_PERM;
        end
        9: req.access.is_store = 1;
        10: begin
          req.access.address = 32'h100e;
          req.access.access_size = 2;
        end
        11: begin
          req.access.address = 32'h100f;
          req.access.access_size = 2;
        end
        default: ;
      endcase
      access_test(1, access_error(metadata, req.access));
    end
    metadata = '{PID_W'(7), 32'hffff_fff0, 32'hf, R_PERM};
    req.access.address = 32'hffff_fffb;
    req.access.access_size = 4;
    access_test(1, GCT_ERR_NONE);
    req.access.address = 32'hffff_fffd;
    access_test(1, GCT_ERR_BOUNDS);  // 4-byte access overflows 32-bit space.

    metadata = '{PID_W'(7), 32'h1000, 32'h10, R_PERM | W_PERM};
    req.access.address = 32'h1004;
    for (int latency = 0; latency < 4; latency++) begin
      lcc_latency = latency;
      access_test(0, access_error(metadata, req.access));
    end
    for (int e = 1; e <= 7; e++) begin
      lookup_error = gct_error_t'(e);
      access_test(0, lookup_error);
    end
    lookup_error = GCT_ERR_NONE;
    $display("[PASS] ACCESS authorization, HIT/MISS, timing and errors");

    for (int phase = 0; phase < 4; phase++) cancel_access(phase);
    cancel_access(2, GCT_ERR_INVALID);
    $display("[PASS] ACCESS cancellation, draining and recovery");

    // Back-to-back combinational HITs, without idle cycles between requests.
    hit_enable = 1;
    pipeline_if.result_ack = 1;
    req.access.access_size = 1;
    for (int i = 0; i < 4; i++) begin
      req.access.address = 32'h1000 + 32'(i);
      req.access.caller_pid = PID_W'(7 + (i % 2));
      start(req);
      assert (pipeline_if.result_valid && pipeline_if.response.error == access_error(
          metadata, req.access
      ))
      else $fatal(1, "Back-to-back HIT mismatch");
      tick();
    end
    pipeline_if.request_valid = 0;
    pipeline_if.result_ack = 0;
    quiet();

    req = '0;
    req.op = CEU_OP_GCT;
    req.gct = '{
        GCT_OP_DERIVE,
        PID_W'(7),
        CAP_IDX_W'(19),
        PID_W'(9),
        32'h1234,
        32'h80,
        R_PERM,
        CSIZE_W'(4)
    };
    for (int test_case = 0; test_case < 8; test_case++) begin
      int unsigned before_count;
      req.gct.op   = gct_op_t'(int'(GCT_OP_DERIVE) + test_case % 3);
      before_count = gct.request_count;
      ready_enable = 0;
      start(req);
      tick();  // CEU_GCT_SEND.
      quiet(3);
      pipeline_if.cancel = 1;
      ready_enable = 1;
      #1;
      assert (!gct_if.new_request)
      else $fatal(1, "Cancelled GCT request was issued");
      tick();
      pipeline_if.cancel = 0;
      pipeline_if.request_valid = 0;
      quiet();
      assert (gct.request_count == before_count)
      else $fatal(1, "Cancelled GCT request accepted");

      gct_latency  = test_case % 4;
      gct_response = '{gct_error_t'(test_case), '0, CAP_IDX_W'(37 + test_case)};
      before_count = gct.request_count;
      ready_enable = 0;
      start(req);
      tick();
      quiet(2);
      ready_enable = 1;
      #1;
      assert (gct_if.new_request && gct_if.request === req.gct)
      else $fatal(1, "Incorrect GCT ready/issue handshake");
      tick();  // Request accepted; no rollback after this point.
      pipeline_if.cancel = 1;
      for (int i = 0; i < TIMEOUT && !gct_if.done; i++) begin
        assert (!pipeline_if.result_valid)
        else $fatal(1, "Early GCT response");
        tick();
      end
      assert (gct_if.done)
      else $fatal(1, "GCT completion timeout");
      assert (!pipeline_if.result_valid)
      else $fatal(1, "Early GCT response");
      expect_response(gct_response.error, int'(gct_response.child_idx), 3);
      pipeline_if.cancel = 0;
      assert (gct.request_count == before_count + 1)
      else $fatal(1, "Missing/duplicate GCT operation");
    end
    $display("[PASS] GCT forwarding, backpressure, completion and cancellation");

    req = '0;
    req.op = CEU_OP_SYNC;
    pipeline_if.cancel = 1;
    start(req);
    assert (!lcc_if.flush)
    else $fatal(1, "Cancelled SYNC flushed LCC");
    tick();
    pipeline_if.cancel = 0;
    pipeline_if.request_valid = 0;
    quiet();

    start(req);
    assert (lcc_if.flush && !pipeline_if.result_valid)
    else $fatal(1, "SYNC should flush before responding");
    tick();
    assert (lcc.flush_count == 1)
    else $fatal(1, "SYNC flush missing/duplicated");
    expect_response(GCT_ERR_NONE);
    assert (lcc.flush_count == 1)
    else $fatal(1, "SYNC flush repeated while waiting for ACK");

    start(req);
    tick();  // Flush has happened.
    pipeline_if.cancel = 1;
    #1;
    assert (!pipeline_if.result_valid)
    else $fatal(1, "Cancelled SYNC response escaped");
    tick();
    pipeline_if.cancel = 0;
    pipeline_if.request_valid = 0;
    quiet();
    assert (lcc.flush_count == 2)
    else $fatal(1, "Cancelled SYNC flush count");

    req = '0;
    req.op = CEU_OP_ACCESS;
    req.access = '{CAP_IDX_W'(19), PID_W'(7), 32'h1004, 4'd4, 1'b0};
    hit_enable = 0;  // Post-SYNC MISS is supplied explicitly by the mock.
    access_test(0, access_error(metadata, req.access));
    $display("[PASS] SYNC flush timing, cancellation and subsequent ACCESS");
    $display("[PASS] All CEU unit tests passed");
    $finish;
  end
endmodule
