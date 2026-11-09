import capability_types::*;

// One outstanding LOOKUP, with response configuration sampled on acceptance.
module lcc_gct_mock (
    input logic clk,
    input logic rst,
    input logic ready_enable,
    input int unsigned response_latency,
    input gct_response_t configured_response,
    global_cap_tree_interface.gct gct_if
);
  logic pending;
  int unsigned cycles_left;
  gct_response_t pending_response;

  assign gct_if.ready = ready_enable && !pending;

  always_ff @(posedge clk) begin
    if (rst) begin
      pending <= 1'b0;
      cycles_left <= 0;
      pending_response <= '0;
      gct_if.done <= 1'b0;
      gct_if.response <= '0;
    end else begin
      gct_if.done <= 1'b0;
      gct_if.response <= '0;
      if (gct_if.new_request) begin
        assert (gct_if.ready && gct_if.request.op == GCT_OP_LOOKUP)
        else $fatal(1, "[FAIL] Invalid GCT request handshake");
        pending <= 1'b1;
        cycles_left <= response_latency;
        pending_response <= configured_response;
      end
      if (pending) begin
        if (cycles_left == 1) begin
          pending <= 1'b0;
          gct_if.done <= 1'b1;
          gct_if.response <= pending_response;
        end else cycles_left <= cycles_left - 1;
      end
    end
  end
endmodule

module tb_local_cap_cache;
  localparam int REQUEST_TIMEOUT = 80;
  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  global_cap_tree_interface gct_if ();
  local_cap_cache_interface ceu_if ();
  logic ready_enable = 1'b1;
  int unsigned response_latency = 1;
  gct_response_t configured_response = '0;
  int unsigned request_count = 0;
  int unsigned simulation_cycles = 0;

  local_cap_cache dut (
      .clk(clk),
      .rst(rst),
      .gct_if(gct_if),
      .ceu_if(ceu_if)
  );
  lcc_gct_mock mock (
      .clk(clk),
      .rst(rst),
      .ready_enable(ready_enable),
      .response_latency(response_latency),
      .configured_response(configured_response),
      .gct_if(gct_if)
  );

  // Every accepted request must belong to the CEU request still being held.
  always @(posedge clk) begin
    simulation_cycles = simulation_cycles + 1;
    if (simulation_cycles > 4000) $fatal(1, "[FAIL] Global watchdog expired");
    if (!rst && gct_if.new_request) begin
      request_count = request_count + 1;
      assert (ceu_if.request && gct_if.request.cap_idx == ceu_if.cap_idx &&
          gct_if.request.caller_pid == ceu_if.caller_pid)
      else $fatal(1, "[FAIL] Incorrect forwarded cap_idx/caller_pid");
    end
  end

  function automatic cap_metadata_t metadata_for(input int unsigned idx);
    cap_metadata_t metadata;
    metadata.owner_pid = PID_W'(idx + 3);
    metadata.base = ADDR_W'(idx * 4096);
    metadata.size = ADDR_W'(256 + idx * 16);
    metadata.permissions = PERM_W'(1 + idx % 7);
    return metadata;
  endfunction

  // Drive on falling edges and sample after settling. Keep the CEU request
  // stable through the rising edge that consumes hit/error.
  task automatic lookup(input int unsigned idx, input int unsigned pid,
                        input cap_metadata_t metadata, input gct_error_t error,
                        input bit expect_hit, input int unsigned stall_cycles = 0,
                        input int unsigned latency = 2);
    int unsigned count_before;
    bit completed;
    lcc_entry_t saved_cache[LCC_ENTRIES];
    logic [LCC_IDX_W-1:0] saved_ptr;

    @(negedge clk);
    count_before = request_count;
    for (int i = 0; i < LCC_ENTRIES; i++) saved_cache[i] = dut.cap_cache_q[i];
    saved_ptr = dut.rr_ptr_q;
    configured_response = '{error: error, metadata: metadata, child_idx: '0};
    response_latency = latency;
    ready_enable = (stall_cycles == 0);
    ceu_if.cap_idx = CAP_IDX_W'(idx);
    ceu_if.caller_pid = PID_W'(pid);
    ceu_if.request = 1'b1;
    #1;
    assert (ceu_if.hit == expect_hit && ceu_if.error == GCT_ERR_NONE)
    else $fatal(1, "[FAIL] Expected initial %s for cap %0d", expect_hit ? "HIT" : "MISS", idx);

    if (expect_hit) begin
      assert (ceu_if.metadata === metadata)
      else $fatal(1, "[FAIL] Combinational HIT metadata mismatch for cap %0d", idx);
    end
    repeat (stall_cycles) begin
      @(negedge clk);
      assert (!gct_if.new_request && request_count == count_before &&
          !ceu_if.hit && ceu_if.error == GCT_ERR_NONE)
      else $fatal(1, "[FAIL] Lookup did not wait for GCT readiness");
    end
    ready_enable = 1'b1;

    completed = expect_hit;
    for (int cycle = 0; cycle < REQUEST_TIMEOUT && !completed; cycle++) begin
      @(negedge clk);
      if (ceu_if.hit || ceu_if.error != GCT_ERR_NONE) completed = 1'b1;
    end
    assert (completed)
    else $fatal(1, "[FAIL] Timeout for cap %0d", idx);
    assert (request_count == count_before + (expect_hit ? 0 : 1))
    else $fatal(1, "[FAIL] Incorrect number of GCT requests for cap %0d", idx);
    assert (ceu_if.error == error && ceu_if.hit == (error == GCT_ERR_NONE))
    else $fatal(1, "[FAIL] Incorrect CEU completion for cap %0d", idx);
    if (error == GCT_ERR_NONE) begin
      assert (ceu_if.metadata === metadata)
      else $fatal(1, "[FAIL] Refill metadata mismatch for cap %0d", idx);
    end else begin
      assert (dut.error_q == error && dut.rr_ptr_q == saved_ptr)
      else $fatal(1, "[FAIL] Error was not registered or changed replacement pointer");
      for (int i = 0; i < LCC_ENTRIES; i++) begin
        assert (dut.cap_cache_q[i] === saved_cache[i])
        else $fatal(1, "[FAIL] Failed lookup modified cache entry %0d", i);
      end
    end

    @(posedge clk);
    #1;
    assert (dut.error_q == GCT_ERR_NONE)
    else $fatal(1, "[FAIL] Consumed error was not cleared");
    @(negedge clk);
    ceu_if.request = 1'b0;
    #1;
    assert (!ceu_if.hit && ceu_if.error == GCT_ERR_NONE)
    else $fatal(1, "[FAIL] CEU completion remained after consumption");
    repeat (2) @(negedge clk);
    assert (request_count == count_before + (expect_hit ? 0 : 1) && !mock.pending)
    else $fatal(1, "[FAIL] Duplicate or unfinished GCT request");
  endtask

  task automatic flush_cache();
    @(negedge clk);
    assert (!ceu_if.request && !mock.pending && dut.state_q == LCC_IDLE)
    else $fatal(1, "[FAIL] Attempt to flush with a pending lookup");
    ceu_if.flush = 1'b1;
    @(negedge clk);
    ceu_if.flush = 1'b0;
    #1;
    for (int i = 0; i < LCC_ENTRIES; i++) begin
      assert (!dut.cap_cache_q[i].valid)
      else $fatal(1, "[FAIL] Flush left entry %0d valid", i);
    end
    assert (dut.rr_ptr_q == 0)
    else $fatal(1, "[FAIL] Flush did not reset replacement pointer");
  endtask

  initial begin
    ceu_if.request = 1'b0;
    ceu_if.cap_idx = '0;
    ceu_if.caller_pid = '0;
    ceu_if.flush = 1'b0;
    repeat (3) @(negedge clk);
    rst = 1'b0;
    for (int i = 0; i < LCC_ENTRIES; i++) begin
      assert (!dut.cap_cache_q[i].valid)
      else $fatal(1, "[FAIL] Reset left valid entry");
    end
    assert (dut.rr_ptr_q == 0)
    else $fatal(1, "[FAIL] Reset pointer is nonzero");

    lookup(5, 17, metadata_for(5), GCT_ERR_NONE, 0);
    lookup(5, 17, metadata_for(5), GCT_ERR_NONE, 1);
    $display("[PASS] Basic MISS/refill and combinational HIT");

    lookup(9, 29, metadata_for(9), GCT_ERR_NONE, 0, 5, 12);
    $display("[PASS] GCT backpressure and outstanding MISS serialization");

    lookup(12, 33, metadata_for(12), GCT_ERR_INVALID, 0);
    lookup(5, 17, metadata_for(5), GCT_ERR_NONE, 1);
    lookup(12, 33, metadata_for(12), GCT_ERR_NONE, 0);
    $display("[PASS] Registered error, consumption, unchanged cache and recovery");

    flush_cache();
    lookup(5, 17, metadata_for(5), GCT_ERR_NONE, 0);
    flush_cache();

    for (int unsigned i = 0; i < LCC_ENTRIES; i++) begin
      lookup(20 + i, 70 + i, metadata_for(20 + i), GCT_ERR_NONE, 0);
      assert (dut.rr_ptr_q == 0)
      else $fatal(1, "[FAIL] Filling invalid entry advanced RR pointer");
      for (int unsigned j = 0; j < LCC_ENTRIES; j++) begin
        assert (dut.cap_cache_q[j].valid == (j <= i))
        else $fatal(1, "[FAIL] Invalid entries were not filled first");
        if (j <= i) begin
          assert (dut.cap_cache_q[j].cap_idx == CAP_IDX_W'(20 + j) &&
              dut.cap_cache_q[j].metadata === metadata_for(
              20 + j
          ))
          else $fatal(1, "[FAIL] Invalid fill replaced an existing capability");
        end
      end
    end

    // An error in a full cache must also preserve the next victim.
    lookup(60, 81, metadata_for(60), GCT_ERR_OWNER, 0);
    for (int unsigned i = 0; i < LCC_ENTRIES + 2; i++) begin
      // HIT the next victim before replacing it: HITs must not move the pointer.
      lookup(i < LCC_ENTRIES ? 20 + i : 40 + i - LCC_ENTRIES, 90, metadata_for(
             i < LCC_ENTRIES ? 20 + i : 40 + i - LCC_ENTRIES), GCT_ERR_NONE, 1);
      assert (dut.rr_ptr_q == LCC_IDX_W'(i % LCC_ENTRIES))
      else $fatal(1, "[FAIL] HIT advanced RR pointer");
      lookup(40 + i, 100 + i, metadata_for(40 + i), GCT_ERR_NONE, 0);
      assert (dut.rr_ptr_q == LCC_IDX_W'((i + 1) % LCC_ENTRIES))
      else $fatal(1, "[FAIL] Incorrect RR advance/wrap");
      for (int unsigned j = 0; j < LCC_ENTRIES; j++) begin
        // Most recent insertion in each slot, or its original fill.
        int unsigned expected_idx;
        if (j > i) expected_idx = 20 + j;
        else expected_idx = 40 + j + ((i - j) / LCC_ENTRIES) * LCC_ENTRIES;
        assert (dut.cap_cache_q[j].valid &&
            dut.cap_cache_q[j].cap_idx == CAP_IDX_W'(expected_idx) &&
            dut.cap_cache_q[j].metadata === metadata_for(
            expected_idx
        ))
        else $fatal(1, "[FAIL] Incorrect RR victim/cache contents at slot %0d", j);
      end
    end
    $display("[PASS] Invalid-first fill, RR replacement/wrap and HIT pointer stability");

    // Pointer is nonzero here, making its flush reset observable.
    flush_cache();
    lookup(49, 111, metadata_for(49), GCT_ERR_NONE, 0);
    $display("[PASS] Flush invalidation, pointer reset and subsequent MISS");
    $display("[PASS] All local_cap_cache tests passed (%0d GCT lookups)", request_count);
    $finish;
  end
endmodule
