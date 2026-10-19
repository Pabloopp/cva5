import capability_types::*;

module tb_global_cap_tree;

  logic clk;
  logic rst;

  // ------------------------------------------------------------
  // Interfaces reales hacia el DUT
  // ------------------------------------------------------------
  global_cap_tree_interface lcc_if[NUM_CORES] ();
  global_cap_tree_interface ceu_if[NUM_CORES] ();

  // ------------------------------------------------------------
  // Señales planas/arrays normales para manejar el TB
  //
  // Importante:
  // El procedural code toca estas señales, no los arrays de interfaces.
  // El generate de abajo conecta estas señales a las interfaces.
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

  initial begin
`ifdef TRACE
    $dumpfile("global_cap_tree_tb.fst");
    $dumpvars(0, tb_global_cap_tree);
`endif
  end

  // ------------------------------------------------------------
  // Adapter TB <-> interfaces
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
  // Clock
  // ------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ------------------------------------------------------------
  // Helpers
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
  // Test sequence
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
  // Main
  // ------------------------------------------------------------
  initial begin
    rst = 1'b1;

    clear_all_drivers();

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    run_tests();

    $display("========================================");
    $display("All GCT tests passed");
    $display("========================================");

    $finish;
  end

endmodule
