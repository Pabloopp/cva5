import capability_types::*;

module local_cap_cache (
    input logic clk,
    input logic rst,

    global_cap_tree_interface.requester gct_if,
    local_cap_cache_interface.lcc ceu_if
);
  //cache_entries
  lcc_entry_t cap_cache_d[LCC_ENTRIES];
  lcc_entry_t cap_cache_q[LCC_ENTRIES];

  // Replacement policy
  logic [LCC_IDX_W-1:0] rr_ptr_d;
  logic [LCC_IDX_W-1:0] rr_ptr_q;
  logic [LCC_IDX_W-1:0] victim_idx;
  logic invalid_found;

  // FSM
  lcc_state_t state_d;
  lcc_state_t state_q;

  // Pending GCT request
  gct_request_t lookup_req_d;
  gct_request_t lookup_req_q;

  // Registered error
  gct_error_t error_d;
  gct_error_t error_q;

  assign gct_if.request = lookup_req_q;

  // Cache lookup and replacement logic
  always_comb begin
    // Defaults
    ceu_if.hit         = 1'b0;
    ceu_if.metadata    = '0;
    ceu_if.error       = GCT_ERR_NONE;
    rr_ptr_d           = rr_ptr_q;
    victim_idx         = rr_ptr_q;
    invalid_found      = 1'b0;
    state_d            = state_q;
    lookup_req_d       = lookup_req_q;
    gct_if.new_request = 1'b0;
    error_d            = error_q;

    for (int unsigned i = 0; i < LCC_ENTRIES; i++) begin
      cap_cache_d[i] = cap_cache_q[i];

      // Fully associative capability lookup
      if (ceu_if.request && cap_cache_q[i].valid &&
        state_q == LCC_IDLE &&
        error_q == GCT_ERR_NONE &&
        !ceu_if.flush &&
        cap_cache_q[i].cap_idx == ceu_if.cap_idx) begin
        ceu_if.hit      = 1'b1;
        ceu_if.metadata = cap_cache_q[i].metadata;
      end

      // Find the first invalid entry
      if (!invalid_found && !cap_cache_q[i].valid) begin
        victim_idx    = LCC_IDX_W'(i);
        invalid_found = 1'b1;
      end

    end
    // FSM
    case (state_q)

      LCC_IDLE: begin
        if (error_q != GCT_ERR_NONE) begin
          if (ceu_if.request) begin
            ceu_if.error = error_q;
            error_d      = GCT_ERR_NONE;
          end

        end else if (ceu_if.flush) begin
          // Invalidate all cache entries
          for (int unsigned i = 0; i < LCC_ENTRIES; i++) begin
            cap_cache_d[i].valid = 1'b0;
          end
          rr_ptr_d = '0;

        end else if (ceu_if.request && !ceu_if.hit) begin
          lookup_req_d            = '0;
          lookup_req_d.op         = GCT_OP_LOOKUP;
          lookup_req_d.cap_idx    = ceu_if.cap_idx;
          lookup_req_d.caller_pid = ceu_if.caller_pid;

          state_d                 = LCC_SEND_GCT;
        end
      end

      LCC_SEND_GCT: begin
        if (gct_if.ready) begin
          gct_if.new_request = 1'b1;
          state_d = LCC_WAIT_GCT;
        end
      end

      LCC_WAIT_GCT: begin
        if (gct_if.done) begin
          if (gct_if.response.error == GCT_ERR_NONE) begin

            // Refill cache
            cap_cache_d[victim_idx].valid    = 1'b1;
            cap_cache_d[victim_idx].cap_idx  = lookup_req_q.cap_idx;
            cap_cache_d[victim_idx].metadata = gct_if.response.metadata;

            // Update RR pointer only when replacing a valid entry
            if (!invalid_found) begin
              if (rr_ptr_q == LCC_IDX_W'(LCC_ENTRIES - 1)) rr_ptr_d = '0;
              else rr_ptr_d = rr_ptr_q + 1'b1;
            end

          end else begin
            // Register GCT error
            error_d = gct_if.response.error;
          end

          state_d = LCC_IDLE;
        end
      end

      default: state_d = LCC_IDLE;

    endcase

    // Future FSM, refill and flush logic
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rr_ptr_q     <= '0;
      state_q      <= LCC_IDLE;
      lookup_req_q <= '0;
      error_q      <= GCT_ERR_NONE;
    end else begin
      rr_ptr_q     <= rr_ptr_d;
      state_q      <= state_d;
      lookup_req_q <= lookup_req_d;
      error_q      <= error_d;
    end
  end

  generate
    for (genvar i = 0; i < LCC_ENTRIES; i++) begin : gen_cap_cache_ff

      always_ff @(posedge clk) begin
        if (rst) begin
          cap_cache_q[i] <= '0;
        end else begin
          cap_cache_q[i] <= cap_cache_d[i];
        end
      end

    end
  endgenerate

endmodule

