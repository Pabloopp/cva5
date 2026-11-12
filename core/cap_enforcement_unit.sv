import capability_types::*;

module cap_enforcement_unit (
    input logic clk,
    input logic rst,

    cap_enforcement_unit_interface.ceu pipeline_if,
    local_cap_cache_interface.ceu lcc_if,
    global_cap_tree_interface.requester gct_if
);

  function automatic gct_error_t check_access(input cap_metadata_t metadata,
                                              input ceu_access_t req);

    logic [  ADDR_W:0] access_end;
    logic [  ADDR_W:0] cap_end;
    logic [PERM_W-1:0] required_perm;

    // Calculate exclusive upper bounds
    access_end = {1'b0, req.address} + (ADDR_W+1)'(req.access_size);
    cap_end    = {1'b0, metadata.base} + {1'b0, metadata.size};

    required_perm = req.is_store ? W_PERM : R_PERM;
    // Ownership
    if (metadata.owner_pid != req.caller_pid) return GCT_ERR_OWNER;
    // Bounds
    if (req.address < metadata.base || access_end > cap_end || access_end > 33'h1_0000_0000)
      return GCT_ERR_BOUNDS;
    // Permissions
    if ((metadata.permissions & required_perm) != required_perm) return GCT_ERR_PERM;

    return GCT_ERR_NONE;

  endfunction


  ceu_state_t state_d;
  ceu_state_t state_q;

  ceu_request_t pending_req_d;
  ceu_request_t pending_req_q;
  ceu_response_t pending_resp_d;
  ceu_response_t pending_resp_q;


  always_comb begin
    // Register defaults
    state_d                  = state_q;
    pending_req_d            = pending_req_q;
    pending_resp_d           = pending_resp_q;
    // Pipeline interface
    pipeline_if.result_valid = 1'b0;
    pipeline_if.response     = '0;
    // LCC interface
    lcc_if.request           = 1'b0;
    lcc_if.cap_idx           = '0;
    lcc_if.caller_pid        = '0;
    lcc_if.flush             = 1'b0;
    // GCT interface
    gct_if.new_request       = 1'b0;
    gct_if.request           = '0;

    case (state_q)

      CEU_IDLE: begin

        if (pipeline_if.request_valid && !pipeline_if.cancel) begin
          case (pipeline_if.request.op)

            CEU_OP_ACCESS: begin
              // Request capability metadata from LCC
              lcc_if.request    = 1'b1;
              lcc_if.cap_idx    = pipeline_if.request.access.cap_idx;
              lcc_if.caller_pid = pipeline_if.request.access.caller_pid;
              if (lcc_if.hit) begin
                // Validate access
                pipeline_if.result_valid = 1'b1;
                pipeline_if.response.error =
                    check_access(lcc_if.metadata, pipeline_if.request.access);
              end else begin
                // Cache miss
                pending_req_d = pipeline_if.request;
                state_d       = CEU_WAIT_LCC;
              end
            end

            CEU_OP_GCT: begin
              // Register management request
              pending_req_d = pipeline_if.request;
              state_d       = CEU_GCT_SEND;
            end

            CEU_OP_SYNC: begin
              // Invalidate local capability cache
              lcc_if.flush         = 1'b1;
              pending_req_d.op     = CEU_OP_SYNC;
              // Prepare successful response
              pending_resp_d       = '0;
              pending_resp_d.error = GCT_ERR_NONE;
              state_d              = CEU_RESPONSE;
            end

            default: begin
              pipeline_if.result_valid   = 1'b1;
              pipeline_if.response.error = GCT_ERR_OP;
            end
          endcase
        end
      end

      CEU_WAIT_LCC: begin
        // Maintain the original lookup request
        lcc_if.request    = 1'b1;
        lcc_if.cap_idx    = pending_req_q.access.cap_idx;
        lcc_if.caller_pid = pending_req_q.access.caller_pid;
        if (pipeline_if.cancel) begin
          state_d = (lcc_if.hit || lcc_if.error != GCT_ERR_NONE) ? CEU_IDLE : CEU_DRAIN;
        end else if (lcc_if.hit || lcc_if.error != GCT_ERR_NONE) begin
          // Store the result
          pending_resp_d = '0;
          pending_resp_d.error = (lcc_if.error != GCT_ERR_NONE) ? lcc_if.error :
              check_access(lcc_if.metadata, pending_req_q.access);
          state_d = CEU_RESPONSE;
        end

      end

      CEU_GCT_SEND: begin
        if (pipeline_if.cancel) begin
          // Request not issued yet: safe to discard
          state_d = CEU_IDLE;
        end else if (gct_if.ready) begin
          // Issue management request
          gct_if.new_request = 1'b1;
          gct_if.request     = pending_req_q.gct;
          state_d            = CEU_GCT_WAIT;
        end
      end

      CEU_GCT_WAIT: begin
        if (gct_if.done) begin
          // Store GCT response
          pending_resp_d           = '0;
          pending_resp_d.error     = gct_if.response.error;
          pending_resp_d.child_idx = gct_if.response.child_idx;
          state_d                  = CEU_RESPONSE;
        end
      end

      CEU_RESPONSE: begin
        if (pipeline_if.cancel && pending_req_q.op != CEU_OP_GCT) begin
          state_d = CEU_IDLE;
        end else begin
          pipeline_if.result_valid = 1'b1;
          pipeline_if.response     = pending_resp_q;
          if (pipeline_if.result_ack) state_d = CEU_IDLE;
        end

      end

      CEU_DRAIN: begin
        // Maintain the cancelled lookup until completion
        lcc_if.request    = 1'b1;
        lcc_if.cap_idx    = pending_req_q.access.cap_idx;
        lcc_if.caller_pid = pending_req_q.access.caller_pid;
        if (lcc_if.hit || lcc_if.error != GCT_ERR_NONE) state_d = CEU_IDLE;
      end

      default: state_d = CEU_IDLE;
    endcase

  end


  always_ff @(posedge clk) begin
    if (rst) begin
      state_q        <= CEU_IDLE;
      pending_req_q  <= '0;
      pending_resp_q <= '0;
    end else begin
      state_q        <= state_d;
      pending_req_q  <= pending_req_d;
      pending_resp_q <= pending_resp_d;
    end
  end
endmodule
