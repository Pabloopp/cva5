import capability_types::*;

module tb_global_cap_tree;

  logic clk;
  logic rst;

  // ------------------------------------------------------------
  // DUT interfaces
  // ------------------------------------------------------------
  global_cap_tree_interface lcc_if[NUM_CORES] ();
  global_cap_tree_interface ceu_if[NUM_CORES] ();

  // ------------------------------------------------------------
  // Flat TB-side signals and arrays
  //
  // Verilator compatibility:
  // Procedural code drives these plain arrays instead of indexing interface arrays.
  // The generate block below bridges them to the actual DUT interfaces.
  // ------------------------------------------------------------
  logic [NUM_CORES-1:0] lcc_new_request;
  logic [NUM_CORES-1:0] ceu_new_request;

  logic [NUM_CORES-1:0] lcc_ready;
  logic [NUM_CORES-1:0] ceu_ready;

  logic [NUM_CORES-1:0] lcc_done;
  logic [NUM_CORES-1:0] ceu_done;

  gct_request_t lcc_request_drv[NUM_CORES];
  gct_request_t ceu_request_drv[NUM_CORES];

  gct_response_t lcc_response_mon[NUM_CORES];
  gct_response_t ceu_response_mon[NUM_CORES];

  // ------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------
  global_cap_tree dut (
      .clk   (clk),
      .rst   (rst),
      .lcc_if(lcc_if),
      .ceu_if(ceu_if)
  );

  // ------------------------------------------------------------
  // Waveform tracing
  // ------------------------------------------------------------
  initial begin
`ifdef TRACE
    $dumpfile("global_cap_tree_tb.fst");
    $dumpvars(0, tb_global_cap_tree);
`endif
  end

  // ------------------------------------------------------------
  // TB-to-interface adapters
  // ------------------------------------------------------------
  generate
    for (genvar c = 0; c < NUM_CORES; c++) begin : gen_tb_if_adapter

      assign lcc_if[c].new_request = lcc_new_request[c];
      assign lcc_if[c].request     = lcc_request_drv[c];

      assign ceu_if[c].new_request = ceu_new_request[c];
      assign ceu_if[c].request     = ceu_request_drv[c];

      assign lcc_ready[c]          = lcc_if[c].ready;
      assign ceu_ready[c]          = ceu_if[c].ready;

      assign lcc_done[c]           = lcc_if[c].done;
      assign ceu_done[c]           = ceu_if[c].done;

      assign lcc_response_mon[c]   = lcc_if[c].response;
      assign ceu_response_mon[c]   = ceu_if[c].response;

    end
  endgenerate

  // ------------------------------------------------------------
  // Clock generation
  // ------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ------------------------------------------------------------
  // Request construction and driver helpers
  // ------------------------------------------------------------
  function automatic gct_request_t make_req(input gct_op_t op, input logic [PID_W-1:0] caller_pid,
                                            input logic [CAP_IDX_W-1:0] cap_idx);
    gct_request_t req;

    req            = '0;
    req.op         = op;
    req.caller_pid = caller_pid;
    req.cap_idx    = cap_idx;

    return req;
  endfunction

  task automatic clear_all_drivers();
    for (int unsigned c = 0; c < NUM_CORES; c++) begin
      lcc_new_request[c] = 1'b0;
      ceu_new_request[c] = 1'b0;

      lcc_request_drv[c] = '0;
      ceu_request_drv[c] = '0;
    end
  endtask

  task automatic issue_lcc_req(input int unsigned core_id, input gct_request_t req,
                               output gct_response_t rsp);
    int cycles;

    if (core_id >= NUM_CORES) begin
      $fatal(1, "[FAIL] LCC core_id %0d out of range", core_id);
    end

    do begin
      @(negedge clk);
    end while (!lcc_ready[core_id]);

    enqueue_expected(0, core_id, 0, gct_response_t'('0));
    lcc_request_drv[core_id] = req;
    lcc_new_request[core_id] = 1'b1;

    @(negedge clk);

    lcc_new_request[core_id] = 1'b0;
    lcc_request_drv[core_id] = '0;

    rsp = '0;

    for (cycles = 0; cycles < 30; cycles++) begin
      @(negedge clk);

      if (lcc_done[core_id]) begin
        rsp = lcc_response_mon[core_id];
        return;
      end
    end

    $fatal(1, "[FAIL] Timeout waiting for LCC response on core %0d", core_id);
  endtask

  task automatic issue_ceu_req(input int unsigned core_id, input gct_request_t req,
                               output gct_response_t rsp);
    int cycles;

    if (core_id >= NUM_CORES) begin
      $fatal(1, "[FAIL] CEU core_id %0d out of range", core_id);
    end

    do begin
      @(negedge clk);
    end while (!ceu_ready[core_id]);

    enqueue_expected(1, core_id, 0, gct_response_t'('0));
    ceu_request_drv[core_id] = req;
    ceu_new_request[core_id] = 1'b1;

    @(negedge clk);

    ceu_new_request[core_id] = 1'b0;
    ceu_request_drv[core_id] = '0;

    rsp = '0;

    for (cycles = 0; cycles < 30; cycles++) begin
      @(negedge clk);

      if (ceu_done[core_id]) begin
        rsp = ceu_response_mon[core_id];
        return;
      end
    end

    $fatal(1, "[FAIL] Timeout waiting for CEU response on core %0d", core_id);
  endtask

  // ------------------------------------------------------------
  // Response expectation helpers
  // ------------------------------------------------------------
  task automatic expect_error(input string test_name, input gct_response_t rsp,
                              input gct_error_t expected_error);
    if (rsp.error !== expected_error) begin
      $fatal(1, "[FAIL] %s: expected error %0d, got %0d", test_name, expected_error, rsp.error);
    end else begin
      $display("[PASS] %s", test_name);
    end
  endtask

  task automatic expect_metadata(
      input string test_name, input cap_metadata_t metadata,
      input logic [PID_W-1:0] expected_owner_pid, input logic [ADDR_W-1:0] expected_base,
      input logic [ADDR_W-1:0] expected_size, input logic [PERM_W-1:0] expected_permissions);
    if (
        (metadata.owner_pid   !== expected_owner_pid) ||
        (metadata.base        !== expected_base) ||
        (metadata.size        !== expected_size) ||
        (metadata.permissions !== expected_permissions)
    ) begin
      $fatal(1, "[FAIL] %s metadata mismatch: owner=%0d base=0x%08h size=0x%08h permissions=0x%0h",
             test_name, metadata.owner_pid, metadata.base, metadata.size, metadata.permissions);
    end else begin
      $display("[PASS] %s metadata", test_name);
    end
  endtask

  task automatic expect_child_idx(input string test_name, input logic [CAP_IDX_W-1:0] got,
                                  input logic [CAP_IDX_W-1:0] expected);
    if (got !== expected) begin
      $fatal(1, "[FAIL] %s: expected child_idx %0d, got %0d", test_name, expected, got);
    end else begin
      $display("[PASS] %s child_idx", test_name);
    end
  endtask

  // ------------------------------------------------------------
  // Response scoreboard and protocol monitor
  // ------------------------------------------------------------
  // Scoreboard entry used to verify response order, routing, and optionally payload.
  typedef struct packed {
    bit is_ceu;
    int unsigned core;
    bit check_payload;
    gct_response_t response;
  } expected_t;
  expected_t expected_responses[$];
  logic [2*NUM_CORES-1:0] previous_done;
  int unsigned accepted_count = 0;
  int unsigned response_count = 0;
  bit saw_full = 0;

  task automatic enqueue_expected(input bit is_ceu, input int unsigned core,
                                  input bit check_payload, input gct_response_t response);
    expected_t item;

    item = '{is_ceu, core, check_payload, response};
    expected_responses.push_back(item);
  endtask

  // Global protocol and scoreboard monitor. Sampling here checks the values seen
  // by the DUT on the current rising edge, before non-blocking updates settle.
  always @(posedge clk) begin : monitor
    expected_t item;

    if (rst) begin
      previous_done = '0;
    end else begin
      // Responses must target at most one requester and pulse for one cycle.
      if (!$onehot0({ceu_done, lcc_done})) $fatal(1, "Multiple response destinations");
      if ((previous_done & {ceu_done, lcc_done}) != '0)
        $fatal(1, "done lasted more than one cycle");
      previous_done = {ceu_done, lcc_done};

      // Count accepted requests and match responses against their queued expectations.
      for (int c = 0; c < NUM_CORES; c++) begin
        if ((ceu_new_request[c] && !ceu_ready[c]) || (lcc_new_request[c] && !lcc_ready[c]))
          $fatal(1, "Requester violated ready protocol");
        accepted_count += int'(ceu_new_request[c]) + int'(lcc_new_request[c]);
        if (ceu_done[c] || lcc_done[c]) begin
          if (expected_responses.size() == 0) $fatal(1, "Unsolicited/duplicate response");
          item = expected_responses.pop_front();
          if (item.core != c || item.is_ceu != ceu_done[c])
            $fatal(
                1,
                "Response order/routing mismatch: expected core %0d CEU=%0b, got core %0d CEU=%0b",
                item.core,
                item.is_ceu,
                c,
                ceu_done[c]
            );
          if (item.check_payload && item.response !==
              (ceu_done[c] ? ceu_response_mon[c] : lcc_response_mon[c]))
            $fatal(1, "Queued response payload mismatch");
          response_count++;
        end
      end

      // Record FIFO saturation for the burst test.
      saw_full |= dut.gct_req_fifo_if.full;

      // Every failed operation, LOOKUP, and non-execution cycle must preserve authority.
      if (dut.gct_state_q != GCT_EXEC || dut.response_d.error != GCT_ERR_NONE ||
          dut.current_entry_q.request.op == GCT_OP_LOOKUP) begin
        for (int i = 0; i < GCT_ENTRIES; i++)
        if (dut.cap_table_d[i] !== dut.cap_table_q[i])
          $fatal(1, "Unexpected table write at index %0d", i);
      end
    end
  end

  // Wait until every accepted request has produced exactly one response.
  task automatic drain_responses();
    for (int cycle = 0; cycle < 300; cycle++) begin
      @(negedge clk);
      if (expected_responses.size() == 0) begin
        repeat (8) @(negedge clk);
        if (accepted_count != response_count)
          $fatal(
              1, "Accepted %0d requests, received %0d responses", accepted_count, response_count
          );
        return;
      end
    end
    $fatal(1, "Timed out draining response scoreboard");
  endtask

  // ------------------------------------------------------------
  // Single-core edge-case tests
  // ------------------------------------------------------------
  task automatic run_edge_tests();
    gct_request_t req;
    gct_response_t rsp;
    logic [CAP_IDX_W-1:0] descendant;

    // ----------------------------------------------------------
    // 1. Derive a descendant from the surviving child
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, PID_W'(4), CAP_IDX_W'(GCT_ENTRIES - 16));
    req.child_owner_pid   = PID_W'(7);
    req.child_base        = ADDR_W'('h5000);
    req.child_size        = ADDR_W'('h10);
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(1);

    issue_ceu_req(0, req, rsp);

    expect_error("derive descendant", rsp, GCT_ERR_NONE);
    descendant = CAP_IDX_W'(GCT_ENTRIES - 9);
    expect_child_idx("derive descendant", rsp.child_idx, descendant);

    // ----------------------------------------------------------
    // 2. Reject permission escalation
    // ----------------------------------------------------------
    req.child_permissions = R_PERM | W_PERM;

    issue_ceu_req(0, req, rsp);

    expect_error("permission escalation", rsp, GCT_ERR_PERM);

    // ----------------------------------------------------------
    // 3. Reject a zero-sized region
    // ----------------------------------------------------------
    req.child_permissions = R_PERM;
    req.child_size        = '0;

    issue_ceu_req(0, req, rsp);

    expect_error("zero-sized region", rsp, GCT_ERR_BOUNDS);

    // ----------------------------------------------------------
    // 4. Reject a zero child reservation
    // ----------------------------------------------------------
    req.child_size  = ADDR_W'('h10);
    req.child_csize = '0;

    issue_ceu_req(0, req, rsp);

    expect_error("zero child reservation", rsp, GCT_ERR_BAD_ARG);

    // ----------------------------------------------------------
    // 5. Reject deletion by the wrong owner
    // ----------------------------------------------------------

    issue_ceu_req(0, make_req(GCT_OP_DELETE, PID_W'(99), CAP_IDX_W'(GCT_ENTRIES - 16)), rsp);

    expect_error("delete wrong owner", rsp, GCT_ERR_OWNER);

    // ----------------------------------------------------------
    // 6. Delete the parent capability
    // ----------------------------------------------------------

    issue_ceu_req(0, make_req(GCT_OP_DELETE, PID_W'(4), CAP_IDX_W'(GCT_ENTRIES - 16)), rsp);

    expect_error("delete parent only", rsp, GCT_ERR_NONE);

    // ----------------------------------------------------------
    // 7. Verify the descendant survives parent deletion
    // ----------------------------------------------------------

    issue_lcc_req(0, make_req(GCT_OP_LOOKUP, PID_W'(7), descendant), rsp);

    expect_error("descendant survives parent delete", rsp, GCT_ERR_NONE);
    expect_metadata("surviving descendant", rsp.metadata, PID_W'(7), ADDR_W'('h5000), ADDR_W'('h10),
                    R_PERM);

    // ----------------------------------------------------------
    // 8. Unsupported operation: REVOKE currently not implemented
    // ----------------------------------------------------------
    // TODO: replace this expectation with functional revoke tests once REVOKE is implemented.

    issue_ceu_req(0, make_req(GCT_OP_REVOKE, ROOT_OWNER_PID, '0), rsp);

    expect_error("unsupported revoke", rsp, GCT_ERR_OP);

    // ----------------------------------------------------------
    // 9. Check every three-bit permission combination
    // ----------------------------------------------------------
    // Exhaust all three-bit permission combinations, including NONE and X-only.
    for (int perm = 0; perm < 8; perm++) begin
      req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
      req.child_owner_pid   = PID_W'(8);
      req.child_base        = ADDR_W'('h8000);
      req.child_size        = ADDR_W'('h10);
      req.child_permissions = PERM_W'(perm);
      req.child_csize       = CSIZE_W'(1);

      issue_ceu_req(0, req, rsp);

      expect_error($sformatf("permission combination %0d", perm), rsp,
                   ((perm & 1) != 0 || perm == 0) ? GCT_ERR_NONE : GCT_ERR_PERM);
    end
  endtask

  // ------------------------------------------------------------
  // Multicore arbitration, routing, and FIFO stress tests
  // ------------------------------------------------------------
  task automatic run_multicore_tests();
    gct_request_t lookup, derive;
    gct_response_t good, bad, child_rsp, rsp;
    int unsigned core1;

    // ----------------------------------------------------------
    // Multicore setup
    // ----------------------------------------------------------
    // Variable indexing deliberately keeps NUM_CORES=1 elaboration legal.
    core1 = 1;
    if (NUM_CORES < 2) begin
      $display("[SKIP] multicore tests (NUM_CORES=%0d)", NUM_CORES);
      return;
    end
    lookup        = make_req(GCT_OP_LOOKUP, ROOT_OWNER_PID, '0);
    good          = '0;
    good.metadata = '{ROOT_OWNER_PID, ROOT_BASE, ROOT_SIZE, ROOT_PERMISSIONS};
    bad           = '0;
    bad.error     = GCT_ERR_OWNER;

    // ----------------------------------------------------------
    // 1. Verify response isolation on core 1
    // ----------------------------------------------------------
    issue_lcc_req(core1, lookup, rsp);
    if (rsp !== good) $fatal(1, "Core 1 lookup payload mismatch");
    drain_responses();
    $display("[PASS] core 1 response isolation");

    // ----------------------------------------------------------
    // 2. Simultaneous LCC requests: fixed priority and routing
    // ----------------------------------------------------------
    // Both LCC requests are accepted at the same rising edge.
    @(negedge clk);
    if (!lcc_ready[0] || !lcc_ready[core1]) $fatal(1, "LCC not ready");
    enqueue_expected(0, 0, 1, good);
    enqueue_expected(0, core1, 1, bad);
    lcc_request_drv[0]     = lookup;
    lcc_request_drv[core1] = make_req(GCT_OP_LOOKUP, PID_W'(99), '0);
    lcc_new_request[0]     = 1;
    lcc_new_request[core1] = 1;
    @(negedge clk);
    lcc_new_request = '0;
    drain_responses();
    $display("[PASS] simultaneous LCC fixed priority and routing");

    // ----------------------------------------------------------
    // 3. Simultaneous CEU derives: serialized allocation
    // ----------------------------------------------------------
    // Same parent, different child owners: allocation indices expose execution order.
    derive                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    derive.child_owner_pid   = PID_W'(5);
    derive.child_base        = ADDR_W'('h6000);
    derive.child_size        = ADDR_W'('h100);
    derive.child_permissions = R_PERM;
    derive.child_csize       = CSIZE_W'(2);
    child_rsp                = '0;
    child_rsp.child_idx      = CAP_IDX_W'(GCT_ENTRIES - 18);
    child_rsp.metadata       = '{PID_W'(5), derive.child_base, derive.child_size, R_PERM};
    @(negedge clk);
    if (!ceu_ready[0] || !ceu_ready[core1]) $fatal(1, "CEU not ready");
    enqueue_expected(1, 0, 1, child_rsp);
    ceu_request_drv[0]           = derive;
    derive.child_owner_pid       = PID_W'(6);
    derive.child_base            = ADDR_W'('h7000);
    child_rsp.child_idx          = CAP_IDX_W'(GCT_ENTRIES - 20);
    child_rsp.metadata.owner_pid = derive.child_owner_pid;
    child_rsp.metadata.base      = derive.child_base;
    enqueue_expected(1, core1, 1, child_rsp);
    ceu_request_drv[core1] = derive;
    ceu_new_request[0]     = 1;
    ceu_new_request[core1] = 1;
    @(negedge clk);
    ceu_new_request = '0;
    drain_responses();
    issue_lcc_req(0, make_req(GCT_OP_LOOKUP, PID_W'(6), child_rsp.child_idx), rsp);
    if (rsp.metadata !== child_rsp.metadata || rsp.error != GCT_ERR_NONE)
      $fatal(1, "Serialized derive state mismatch");
    $display("[PASS] simultaneous CEU derives serialize authority changes");
    drain_responses();

    // ----------------------------------------------------------
    // 4. CEU delete takes priority over an LCC lookup
    // ----------------------------------------------------------
    // Higher-index CEU deletes before lower-index LCC observes the entry.
    @(negedge clk);
    enqueue_expected(1, core1, 1, gct_response_t'('0));
    bad.error = GCT_ERR_INVALID;
    enqueue_expected(0, 0, 1, bad);
    ceu_request_drv[core1] = make_req(GCT_OP_DELETE, PID_W'(6), child_rsp.child_idx);
    lcc_request_drv[0]     = make_req(GCT_OP_LOOKUP, PID_W'(6), child_rsp.child_idx);
    ceu_new_request[core1] = 1;
    lcc_new_request[0]     = 1;
    @(negedge clk);
    ceu_new_request = '0;
    lcc_new_request = '0;
    drain_responses();
    $display("[PASS] CEU priority over lower-index LCC; pending lookup preserved");

    // ----------------------------------------------------------
    // 5. FIFO saturation, ordering, and backpressure
    // ----------------------------------------------------------
    // Sustained arrivals exceed service rate, fill FIFO, and exercise pending backpressure.
    // One source gives an unambiguous FIFO order even while arbitration is stalled.
    bad.error = GCT_ERR_OWNER;
    saw_full  = 0;
    for (int n = 0; n < 24; n++) begin
      do @(negedge clk); while (!lcc_ready[core1]);
      enqueue_expected(0, core1, 1, (n % 2 == 0) ? good : bad);
      lcc_request_drv[core1] =
          make_req(GCT_OP_LOOKUP, (n % 2 == 0) ? ROOT_OWNER_PID : PID_W'(99), '0);
      lcc_new_request[core1] = 1;
      @(negedge clk);
      lcc_new_request[core1] = 0;
    end
    drain_responses();
    if (!saw_full) $fatal(1, "Burst did not fill FIFO");
    $display("[PASS] FIFO saturation, ordering, backpressure, and response conservation");
  endtask

  // ------------------------------------------------------------
  // Single-core functional tests
  // ------------------------------------------------------------
  task automatic run_tests();
    gct_request_t req;
    gct_response_t rsp;

    logic [CAP_IDX_W-1:0] child0_idx;
    logic [CAP_IDX_W-1:0] child1_idx;

    int unsigned core0;

    core0 = 0;

    child0_idx = CAP_IDX_W'(GCT_ENTRIES - 8);
    child1_idx = CAP_IDX_W'(GCT_ENTRIES - 16);

    // ----------------------------------------------------------
    // 1. Lookup root capability from LCC
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, ROOT_OWNER_PID, '0);

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup root from LCC", rsp, GCT_ERR_NONE);
    expect_metadata("lookup root from LCC", rsp.metadata, ROOT_OWNER_PID, ROOT_BASE, ROOT_SIZE,
                    ROOT_PERMISSIONS);

    // ----------------------------------------------------------
    // 2. Lookup root with wrong owner
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, PID_W'(2), '0);

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup root wrong owner", rsp, GCT_ERR_OWNER);

    // ----------------------------------------------------------
    // 3. Lookup invalid capability
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, ROOT_OWNER_PID, CAP_IDX_W'(10));

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup invalid capability", rsp, GCT_ERR_INVALID);

    // ----------------------------------------------------------
    // 4. Valid derive from root
    //
    // root.cfree initially = 128
    // child_csize = 8
    // child_idx = 0 + 128 - 8 = 120
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    req.child_owner_pid   = PID_W'(2);
    req.child_base        = 32'h0000_1000;
    req.child_size        = 32'h0000_1000;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(8);

    issue_ceu_req(core0, req, rsp);

    expect_error("valid derive from root", rsp, GCT_ERR_NONE);
    expect_child_idx("valid derive from root", rsp.child_idx, child0_idx);
    expect_metadata("valid derive from root", rsp.metadata, PID_W'(2), 32'h0000_1000, 32'h0000_1000,
                    R_PERM);

    // ----------------------------------------------------------
    // 5. Lookup derived child with correct owner
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, PID_W'(2), child0_idx);

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup derived child", rsp, GCT_ERR_NONE);
    expect_metadata("lookup derived child", rsp.metadata, PID_W'(2), 32'h0000_1000, 32'h0000_1000,
                    R_PERM);

    // ----------------------------------------------------------
    // 6. Lookup derived child with wrong owner
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, ROOT_OWNER_PID, child0_idx);

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup derived child wrong owner", rsp, GCT_ERR_OWNER);

    // ----------------------------------------------------------
    // 7. Derive with address overflow
    //
    // child_base + child_size wraps around, so:
    // child_end <= child_base
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    req.child_owner_pid   = PID_W'(3);
    req.child_base        = 32'hFFFF_FF00;
    req.child_size        = 32'h0000_0200;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(4);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive address overflow", rsp, GCT_ERR_BOUNDS);

    // ----------------------------------------------------------
    // 8. Derive with invalid permissions
    //
    // W-only is invalid because valid permissions require R or NONE.
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    req.child_owner_pid   = PID_W'(3);
    req.child_base        = 32'h0000_3000;
    req.child_size        = 32'h0000_0100;
    req.child_permissions = W_PERM;
    req.child_csize       = CSIZE_W'(4);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive invalid permissions", rsp, GCT_ERR_PERM);

    // ----------------------------------------------------------
    // 9. Derive with no space from child
    //
    // child0.cfree = 8
    // child_csize = 8
    // parent.cfree <= child_csize, so this must fail.
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, PID_W'(2), child0_idx);
    req.child_owner_pid   = PID_W'(3);
    req.child_base        = 32'h0000_1100;
    req.child_size        = 32'h0000_0100;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(8);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive no space", rsp, GCT_ERR_NO_SPACE);

    // ----------------------------------------------------------
    // 10. Derive with invalid child owner
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    req.child_owner_pid   = INVALID_PID;
    req.child_base        = 32'h0000_4000;
    req.child_size        = 32'h0000_0100;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(4);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive invalid child owner", rsp, GCT_ERR_BAD_ARG);

    // ----------------------------------------------------------
    // 11. Derive with out-of-parent bounds
    //
    // child0 covers [0x1000, 0x2000).
    // This requested child starts outside that region.
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, PID_W'(2), child0_idx);
    req.child_owner_pid   = PID_W'(3);
    req.child_base        = 32'h0000_3000;
    req.child_size        = 32'h0000_0100;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(1);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive out of parent bounds", rsp, GCT_ERR_BOUNDS);

    // ----------------------------------------------------------
    // 12. Delete root should fail
    // ----------------------------------------------------------
    req = make_req(GCT_OP_DELETE, ROOT_OWNER_PID, '0);

    issue_ceu_req(core0, req, rsp);

    expect_error("delete root", rsp, GCT_ERR_BAD_ARG);

    // ----------------------------------------------------------
    // 13. Delete derived child
    // ----------------------------------------------------------
    req = make_req(GCT_OP_DELETE, PID_W'(2), child0_idx);

    issue_ceu_req(core0, req, rsp);

    expect_error("delete derived child", rsp, GCT_ERR_NONE);

    // ----------------------------------------------------------
    // 14. Lookup deleted child should fail as invalid
    // ----------------------------------------------------------
    req = make_req(GCT_OP_LOOKUP, PID_W'(2), child0_idx);

    issue_lcc_req(core0, req, rsp);

    expect_error("lookup deleted child", rsp, GCT_ERR_INVALID);

    // ----------------------------------------------------------
    // 15. Derive again from root
    //
    // DELETE does not restore root.cfree.
    // After first valid derive, root.cfree = 120.
    // New child_csize = 8:
    // child_idx = 0 + 120 - 8 = 112
    // ----------------------------------------------------------
    req                   = make_req(GCT_OP_DERIVE, ROOT_OWNER_PID, '0);
    req.child_owner_pid   = PID_W'(4);
    req.child_base        = 32'h0000_5000;
    req.child_size        = 32'h0000_0100;
    req.child_permissions = R_PERM;
    req.child_csize       = CSIZE_W'(8);

    issue_ceu_req(core0, req, rsp);

    expect_error("derive after delete", rsp, GCT_ERR_NONE);
    expect_child_idx("derive after delete", rsp.child_idx, child1_idx);
    expect_metadata("derive after delete", rsp.metadata, PID_W'(4), 32'h0000_5000, 32'h0000_0100,
                    R_PERM);

    // ----------------------------------------------------------
    // 16. Unsupported operation: PRELOAD currently not implemented
    // ----------------------------------------------------------
    req = make_req(GCT_OP_PRELOAD, ROOT_OWNER_PID, '0);

    issue_ceu_req(core0, req, rsp);

    expect_error("unsupported preload op", rsp, GCT_ERR_OP);

  endtask

  // ------------------------------------------------------------
  // Testbench entry point
  // ------------------------------------------------------------
  initial begin
    rst = 1'b1;

    clear_all_drivers();

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // Verify the complete capability table reset state before issuing any request.
    if (dut.cap_table_q[0] !== ROOT_CAPABILITY) $fatal(1, "Root reset mismatch");
    for (int i = 1; i < GCT_ENTRIES; i++)
    if (dut.cap_table_q[i] !== gct_entry_t'('0)) $fatal(1, "Non-root reset mismatch");

    // Run in order: later suites use capabilities created by earlier suites.
    run_tests();
    drain_responses();

    run_multicore_tests();
    drain_responses();

    run_edge_tests();
    drain_responses();

    $display("========================================");
    $display("All GCT tests passed");
    $display("========================================");

    $finish;
  end

endmodule
