
`timescale 1ns / 1ps
import capability_types::*;

// Integration test: real CEU + real LCC + real GCT, one core.
// All stimulus and functional checks use the pipeline-facing CEU interface.
// No internal table/cache inspection and no mocked responses.
module tb_cap_subsystem;

  localparam int RESPONSE_TIMEOUT = 120;
  localparam int PATH_ANY = 0;
  localparam int PATH_COMBINATIONAL = 1;
  localparam int PATH_REGISTERED = 2;

  localparam logic [PID_W-1:0] PID_ROOT = PID_W'(1);
  localparam logic [PID_W-1:0] PID_CHILD = PID_W'(2);
  localparam logic [PID_W-1:0] PID_GRANDCHILD = PID_W'(3);
  localparam logic [CAP_IDX_W-1:0] CHILD_IDX = CAP_IDX_W'(120);
  localparam logic [CAP_IDX_W-1:0] GRANDCHILD_IDX = CAP_IDX_W'(126);

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  cap_enforcement_unit_interface pipeline_if ();
  local_cap_cache_interface lcc_if ();
  global_cap_tree_interface lcc_gct_if[NUM_CORES] ();
  global_cap_tree_interface ceu_gct_if[NUM_CORES] ();

  cap_enforcement_unit ceu (
      .clk(clk),
      .rst(rst),
      .pipeline_if(pipeline_if),
      .lcc_if(lcc_if),
      .gct_if(ceu_gct_if[0])
  );

  local_cap_cache lcc (
      .clk(clk),
      .rst(rst),
      .gct_if(lcc_gct_if[0]),
      .ceu_if(lcc_if)
  );

  global_cap_tree gct (
      .clk(clk),
      .rst(rst),
      .lcc_if(lcc_gct_if),
      .ceu_if(ceu_gct_if)
  );

  // If NUM_CORES > 1, unused requesters must not inject requests.
  for (genvar i = 1; i < NUM_CORES; i++) begin : gen_unused_cores
    assign lcc_gct_if[i].new_request = 1'b0;
    assign lcc_gct_if[i].request = '0;
    assign ceu_gct_if[i].new_request = 1'b0;
    assign ceu_gct_if[i].request = '0;
  end

  int unsigned tests_passed = 0;

  initial begin : watchdog
    #100000;
    $fatal(1, "[FAIL] Global simulation watchdog expired");
  end

  function automatic ceu_request_t access_req(
      input logic [CAP_IDX_W-1:0] idx, input logic [PID_W-1:0] pid, input logic [ADDR_W-1:0] addr,
      input int unsigned bytes, input bit is_store);
    ceu_request_t q = '0;
    q.op = CEU_OP_ACCESS;
    q.access.cap_idx = idx;
    q.access.caller_pid = pid;
    q.access.address = addr;
    q.access.access_size = 4'(bytes);
    q.access.is_store = is_store;
    return q;
  endfunction

  function automatic ceu_request_t management_req(
      input gct_op_t operation, input logic [CAP_IDX_W-1:0] idx, input logic [PID_W-1:0] caller);
    ceu_request_t q = '0;
    q.op = CEU_OP_GCT;
    q.gct.op = operation;
    q.gct.cap_idx = idx;
    q.gct.caller_pid = caller;
    return q;
  endfunction

  function automatic ceu_request_t derive_req(
      input logic [CAP_IDX_W-1:0] parent_idx, input logic [PID_W-1:0] caller,
      input logic [PID_W-1:0] child_owner, input logic [ADDR_W-1:0] base,
      input logic [ADDR_W-1:0] size, input logic [PERM_W-1:0] perms, input int unsigned slots);
    ceu_request_t q;
    q = management_req(GCT_OP_DERIVE, parent_idx, caller);
    q.gct.child_owner_pid = child_owner;
    q.gct.child_base = base;
    q.gct.child_size = size;
    q.gct.child_permissions = perms;
    q.gct.child_csize = 8'(slots);
    return q;
  endfunction

  function automatic ceu_request_t sync_req();
    ceu_request_t q = '0;
    q.op = CEU_OP_SYNC;
    return q;
  endfunction

  task automatic assert_response(input string name, input gct_error_t expected_error,
                                 input bit check_child_idx,
                                 input logic [CAP_IDX_W-1:0] expected_child_idx);
    if (!pipeline_if.result_valid) $fatal(1, "[FAIL] %s: result_valid not asserted", name);
    if (pipeline_if.response.error !== expected_error)
      $fatal(
          1,
          "[FAIL] %s: expected error=%0d, observed error=%0d",
          name,
          expected_error,
          pipeline_if.response.error
      );
    if (check_child_idx && pipeline_if.response.child_idx !== expected_child_idx)
      $fatal(
          1,
          "[FAIL] %s: expected child_idx=%0d, observed child_idx=%0d",
          name,
          expected_child_idx,
          pipeline_if.response.child_idx
      );
  endtask

  // Drive exactly one operation. For a combinational ACCESS hit, keep
  // request_valid asserted through the response. For registered responses,
  // remove request_valid after the first accepting edge and wait for valid.
  // ACK delay checks that registered responses remain stable under backpressure.
  task automatic transact(
      input string name, input ceu_request_t q, input gct_error_t expected_error, input int path,
      input bit check_child_idx = 1'b0, input logic [CAP_IDX_W-1:0] expected_child_idx = '0,
      input int unsigned ack_delay = 0);
    bit immediate;
    bit completed;
    ceu_response_t stable_response;

    @(negedge clk);
    pipeline_if.request = q;
    pipeline_if.cancel = 1'b0;
    pipeline_if.result_ack = 1'b0;
    pipeline_if.request_valid = 1'b1;
    #1;

    immediate = pipeline_if.result_valid;
    if (path == PATH_COMBINATIONAL && !immediate)
      $fatal(1, "[FAIL] %s: expected combinational response", name);
    if (path == PATH_REGISTERED && immediate)
      $fatal(1, "[FAIL] %s: unexpected combinational response", name);

    if (!immediate) begin
      @(posedge clk);  // CEU captures the request.
      @(negedge clk);
      pipeline_if.request_valid = 1'b0;
      completed = 1'b0;
      for (int unsigned i = 0; i < RESPONSE_TIMEOUT; i++) begin
        #1;
        if (pipeline_if.result_valid) begin
          completed = 1'b1;
          break;
        end
        @(negedge clk);
      end
      if (!completed) $fatal(1, "[FAIL] %s: response timeout", name);
    end

    assert_response(name, expected_error, check_child_idx, expected_child_idx);
    stable_response = pipeline_if.response;

    // Retain the response without acknowledging it.
    repeat (ack_delay) begin
      @(negedge clk);
      #1;
      assert_response(name, expected_error, check_child_idx, expected_child_idx);
      if (pipeline_if.response !== stable_response)
        $fatal(1, "[FAIL] %s: response changed before ACK", name);
    end

    pipeline_if.result_ack = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pipeline_if.request_valid = 1'b0;
    pipeline_if.result_ack = 1'b0;
    #1;
    if (pipeline_if.result_valid) $fatal(1, "[FAIL] %s: stale result_valid after ACK", name);

    tests_passed++;
    $display("[PASS] %-44s error=%0d", name, expected_error);
  endtask

  // A cache miss is cancelled after it is accepted. The CEU must drain
  // the lookup and suppress its result, without requiring a pipeline ACK.
  task automatic cancel_lookup();
    @(negedge clk);
    pipeline_if.request = access_req(CAP_IDX_W'(127), PID_ROOT, 32'h4000, 4, 1'b0);
    pipeline_if.request_valid = 1'b1;
    pipeline_if.result_ack = 1'b0;
    pipeline_if.cancel = 1'b0;
    #1;
    if (pipeline_if.result_valid) $fatal(1, "[FAIL] cancellation test unexpectedly hit the LCC");

    @(posedge clk);  // Enter CEU_WAIT_LCC.
    @(negedge clk);
    pipeline_if.request_valid = 1'b0;
    pipeline_if.cancel = 1'b1;
    #1;
    if (pipeline_if.result_valid)
      $fatal(1, "[FAIL] cancelled lookup exposed an authorization result");
    @(posedge clk);
    @(negedge clk);
    pipeline_if.cancel = 1'b0;

    // Allow the real GCT lookup to complete. No response is permitted.
    repeat (RESPONSE_TIMEOUT) begin
      #1;
      if (pipeline_if.result_valid) $fatal(1, "[FAIL] cancelled lookup leaked a result");
      @(negedge clk);
    end
    tests_passed++;
    $display("[PASS] Cancelled LCC miss drains without a response");
  endtask

  // Discard a management request during CEU_GCT_SEND, before GCT acceptance.
  task automatic cancel_management_before_accept();
    ceu_request_t q;
    q = derive_req(CAP_IDX_W'(0), PID_ROOT, PID_W'(4), 32'h3000, 32'h100, R_PERM, 4);
    @(negedge clk);
    pipeline_if.request = q;
    pipeline_if.request_valid = 1'b1;
    pipeline_if.result_ack = 1'b0;
    pipeline_if.cancel = 1'b0;
    @(posedge clk);  // CEU_IDLE -> CEU_GCT_SEND (nothing sent yet).
    @(negedge clk);
    pipeline_if.request_valid = 1'b0;
    pipeline_if.cancel = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pipeline_if.cancel = 1'b0;
    repeat (10) @(negedge clk);
    if (pipeline_if.result_valid)
      $fatal(1, "[FAIL] cancelled management request returned a response");
    tests_passed++;
    $display("[PASS] Management request cancelled before GCT acceptance");
  endtask

  // After the management request has been accepted by the GCT,
  // subsequent cancellation cannot undo it or suppress its response.
  task automatic accepted_management_survives_cancel();
    ceu_request_t q;
    bit seen;
    q = derive_req(CAP_IDX_W'(0), PID_ROOT, PID_W'(4), 32'h3000, 32'h100, R_PERM, 4);
    @(negedge clk);
    pipeline_if.request = q;
    pipeline_if.request_valid = 1'b1;
    pipeline_if.result_ack = 1'b0;
    pipeline_if.cancel = 1'b0;

    @(posedge clk);  // IDLE -> GCT_SEND.
    @(negedge clk);
    pipeline_if.request_valid = 1'b0;
    @(posedge clk);  // GCT_SEND -> GCT_WAIT, GCT accepts request.
    @(negedge clk);
    pipeline_if.cancel = 1'b1;

    seen = 1'b0;
    for (int unsigned i = 0; i < RESPONSE_TIMEOUT; i++) begin
      #1;
      if (pipeline_if.result_valid) begin
        seen = 1'b1;
        break;
      end
      @(negedge clk);
    end
    if (!seen) $fatal(1, "[FAIL] Accepted GCT operation did not complete");
    assert_response("Accepted DERIVE despite late cancel", GCT_ERR_NONE, 1'b1, CAP_IDX_W'(116));

    // Even with cancel high, a GCT result must remain until ACK.
    repeat (2) begin
      @(negedge clk);
      #1;
      assert_response("GCT response retained under cancellation", GCT_ERR_NONE, 1'b1,
                      CAP_IDX_W'(116));
    end
    pipeline_if.result_ack = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pipeline_if.result_ack = 1'b0;
    pipeline_if.cancel = 1'b0;
    #1;
    if (pipeline_if.result_valid) $fatal(1, "[FAIL] GCT response remained valid after ACK");
    tests_passed++;
    $display("[PASS] Accepted GCT operation completes despite late cancel");
  endtask

  initial begin : test_sequence
    pipeline_if.request_valid = 1'b0;
    pipeline_if.request = '0;
    pipeline_if.cancel = 1'b0;
    pipeline_if.result_ack = 1'b0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // Root capability is initialized by GCT reset.
    transact("Root read: cold LCC miss", access_req(0, PID_ROOT, 32'h1000, 4, 0), GCT_ERR_NONE,
             PATH_REGISTERED, 0, '0, 2);
    transact("Root write: cached combinational hit", access_req(0, PID_ROOT, 32'h1000, 4, 1),
             GCT_ERR_NONE, PATH_COMBINATIONAL);
    transact("Root rejects overflowing access", access_req(0, PID_ROOT, 32'hffff_fffe, 4, 0),
             GCT_ERR_BOUNDS, PATH_COMBINATIONAL);
    transact("Cached root rejects wrong owner", access_req(0, PID_CHILD, 32'h1000, 4, 0),
             GCT_ERR_OWNER, PATH_COMBINATIONAL);
    transact("Unknown capability fails LOOKUP", access_req(CAP_IDX_W'(127), PID_ROOT, 32'h4000, 4, 0
             ), GCT_ERR_INVALID, PATH_REGISTERED);

    // Invalid DERIVE must not consume the parent's reservation.
    transact("DERIVE rejects zero reserved slots", derive_req(
             0, PID_ROOT, PID_CHILD, 32'h1000, 32'h100, R_PERM, 0), GCT_ERR_BAD_ARG,
             PATH_REGISTERED);

    transact("DERIVE rejects out-of-bounds child", derive_req(
             0, PID_ROOT, PID_CHILD, 32'hffff_fff0, 32'h40, R_PERM, 8), GCT_ERR_BOUNDS,
             PATH_REGISTERED);
    transact("DERIVE rejects invalid permissions", derive_req(
             0, PID_ROOT, PID_CHILD, 32'h1000, 32'h100, W_PERM, 8), GCT_ERR_PERM, PATH_REGISTERED);

    // Root.cfree starts at 128; reserving 8 slots yields index 120.
    transact("DERIVE child from root", derive_req(
             0, PID_ROOT, PID_CHILD, 32'h1000, 32'h100, R_PERM, 8), GCT_ERR_NONE, PATH_REGISTERED,
             1, CHILD_IDX, 2);
    transact("Child read: cold LCC miss", access_req(CHILD_IDX, PID_CHILD, 32'h1010, 4, 0),
             GCT_ERR_NONE, PATH_REGISTERED);
    transact("Child read: cached LCC hit", access_req(CHILD_IDX, PID_CHILD, 32'h1014, 4, 0),
             GCT_ERR_NONE, PATH_COMBINATIONAL);
    transact("Child rejects write permission", access_req(CHILD_IDX, PID_CHILD, 32'h1010, 4, 1),
             GCT_ERR_PERM, PATH_COMBINATIONAL);
    transact("Child rejects wrong owner", access_req(CHILD_IDX, PID_ROOT, 32'h1010, 4, 0),
             GCT_ERR_OWNER, PATH_COMBINATIONAL);
    transact("Child rejects address below base", access_req(CHILD_IDX, PID_CHILD, 32'h0fff, 1, 0),
             GCT_ERR_BOUNDS, PATH_COMBINATIONAL);
    transact("Child accepts last valid byte", access_req(CHILD_IDX, PID_CHILD, 32'h10ff, 1, 0),
             GCT_ERR_NONE, PATH_COMBINATIONAL);
    transact("Child rejects crossing upper bound", access_req(CHILD_IDX, PID_CHILD, 32'h10ff, 2, 0),
             GCT_ERR_BOUNDS, PATH_COMBINATIONAL);

    // Child has csize=8 and cfree=8; reserving 2 slots yields index 126.
    transact("DERIVE grandchild from child", derive_req(
             CHILD_IDX, PID_CHILD, PID_GRANDCHILD, 32'h1020, 32'h20, R_PERM, 2), GCT_ERR_NONE,
             PATH_REGISTERED, 1, GRANDCHILD_IDX);
    transact("Grandchild read: cold LCC miss", access_req(
             GRANDCHILD_IDX, PID_GRANDCHILD, 32'h1024, 4, 0), GCT_ERR_NONE, PATH_REGISTERED);
    transact("Grandchild read: cached LCC hit", access_req(
             GRANDCHILD_IDX, PID_GRANDCHILD, 32'h1028, 4, 0), GCT_ERR_NONE, PATH_COMBINATIONAL);

    // REVOKE invalidates descendants in the GCT, not cached copies.
    transact("REVOKE child descendants", management_req(GCT_OP_REVOKE, CHILD_IDX, PID_CHILD),
             GCT_ERR_NONE, PATH_REGISTERED);
    transact("Stale grandchild remains cached before SYNC", access_req(
             GRANDCHILD_IDX, PID_GRANDCHILD, 32'h1024, 4, 0), GCT_ERR_NONE, PATH_COMBINATIONAL);
    transact("SYNC flushes local LCC", sync_req(), GCT_ERR_NONE, PATH_REGISTERED);
    transact("Revoked grandchild fails after SYNC", access_req(
             GRANDCHILD_IDX, PID_GRANDCHILD, 32'h1024, 4, 0), GCT_ERR_INVALID, PATH_REGISTERED);
    transact("REVOKE preserved its parent", access_req(CHILD_IDX, PID_CHILD, 32'h1010, 4, 0),
             GCT_ERR_NONE, PATH_REGISTERED);

    // Management requests also enforce ownership.
    transact("DELETE rejects wrong caller", management_req(GCT_OP_DELETE, CHILD_IDX, PID_ROOT),
             GCT_ERR_OWNER, PATH_REGISTERED);

    // DELETE similarly requires an explicit synchronization.
    transact("DELETE child", management_req(GCT_OP_DELETE, CHILD_IDX, PID_CHILD), GCT_ERR_NONE,
             PATH_REGISTERED);
    transact("Stale deleted child remains cached before SYNC", access_req(
             CHILD_IDX, PID_CHILD, 32'h1010, 4, 0), GCT_ERR_NONE, PATH_COMBINATIONAL);
    transact("SYNC after DELETE", sync_req(), GCT_ERR_NONE, PATH_REGISTERED);
    transact("Deleted child fails after SYNC", access_req(CHILD_IDX, PID_CHILD, 32'h1010, 4, 0),
             GCT_ERR_INVALID, PATH_REGISTERED);
    transact("Root cannot be deleted", management_req(GCT_OP_DELETE, 0, PID_ROOT), GCT_ERR_BAD_ARG,
             PATH_REGISTERED);

    // Cancellation on a real pending GCT-backed LCC lookup.
    cancel_lookup();
    transact("Pipeline recovers after cancelled lookup", access_req(0, PID_ROOT, 32'h2000, 4, 0),
             GCT_ERR_NONE, PATH_ANY);

    // After allocating 8 slots under root, its next 4-slot child would
    // be index 116. If the cancelled DERIVE was wrongly submitted, that
    // capability would become visible here.
    cancel_management_before_accept();
    transact("Cancelled DERIVE did not modify GCT", access_req(
             CAP_IDX_W'(116), PID_W'(4), 32'h3000, 4, 0), GCT_ERR_INVALID, PATH_REGISTERED);

    accepted_management_survives_cancel();
    transact("Accepted DERIVE is visible through CEU ACCESS", access_req(
             CAP_IDX_W'(116), PID_W'(4), 32'h3000, 4, 0), GCT_ERR_NONE, PATH_REGISTERED);

    $display("[PASS] All subsystem integration tests passed (%0d checks)", tests_passed);
    $finish;
  end
endmodule
