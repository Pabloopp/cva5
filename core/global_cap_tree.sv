import capability_types::*;

module global_cap_tree (
    input logic clk,
    input logic rst,

    // One GCT interface per core.
    global_cap_tree_interface.gct lcc_if[NUM_CORES],
    global_cap_tree_interface.gct ceu_if[NUM_CORES]
);

  function automatic cap_metadata_t entry_to_metadata(input gct_entry_t entry);
    cap_metadata_t metadata;

    metadata             = '0;

    metadata.owner_pid   = entry.owner_pid;
    metadata.base        = entry.base;
    metadata.size        = entry.size;
    metadata.permissions = entry.permissions;

    return metadata;
  endfunction

  function automatic logic valid_permissions(input logic [PERM_W-1:0] permissions);
    return (((permissions & R_PERM) == R_PERM) || (permissions == PERM_NONE));
  endfunction


  // Capability tree
  gct_entry_t cap_table_q[GCT_ENTRIES];
  gct_entry_t cap_table_d[GCT_ENTRIES];

  // Frontend + arbiter signals
  gct_request_t ceu_pending_req_q[NUM_CORES];
  gct_request_t lcc_pending_req_q[NUM_CORES];

  logic [NUM_CORES-1:0] ceu_pending_valid_q;
  logic [NUM_CORES-1:0] lcc_pending_valid_q;

  logic [NUM_CORES-1:0] ceu_pending_to_fifo;
  logic [NUM_CORES-1:0] lcc_pending_to_fifo;

  logic [NUM_CORES-1:0] ceu_grant_oh;
  logic [NUM_CORES-1:0] lcc_grant_oh;

  logic ceu_pending_any;

  // FIFO iface
  fifo_interface #(.DATA_TYPE(gct_fifo_entry_t)) gct_req_fifo_if ();

  // FIFO output
  gct_fifo_entry_t current_entry_d;
  gct_fifo_entry_t current_entry_q;

  // FSM
  gct_state_t gct_state_d;
  gct_state_t gct_state_q;

  // Derive combinational signals
  logic [CAP_IDX_W-1:0] derive_parent_idx;
  logic [CAP_IDX_W-1:0] derive_child_idx;
  logic [CSIZE_W-1:0] derive_child_idx_ext;

  gct_entry_t derive_parent_entry;
  gct_entry_t derive_child_entry;

  logic [ADDR_W-1:0] derive_child_end;
  logic [ADDR_W-1:0] derive_parent_end;

  // Response
  gct_response_t response_d;
  gct_response_t response_q;

  // Front end to serialize the requests
  // NOTE: It is assumed that requests can only be received while ready = 1
  generate
    for (genvar c = 0; c < NUM_CORES; c++) begin : gen_req_frontend
      assign ceu_if[c].ready = !ceu_pending_valid_q[c];
      assign lcc_if[c].ready = !lcc_pending_valid_q[c];

      always_ff @(posedge clk) begin : req_frontend
        if (rst) begin
          ceu_pending_valid_q[c] <= '0;
          ceu_pending_req_q[c]   <= '0;
          lcc_pending_valid_q[c] <= '0;
          lcc_pending_req_q[c]   <= '0;
        end else begin
          if (ceu_pending_to_fifo[c]) begin
            ceu_pending_valid_q[c] <= 1'b0;
          end

          if (lcc_pending_to_fifo[c]) begin
            lcc_pending_valid_q[c] <= 1'b0;
          end

          if (ceu_if[c].new_request) begin
            ceu_pending_valid_q[c] <= 1'b1;
            ceu_pending_req_q[c]   <= ceu_if[c].request;
          end

          if (lcc_if[c].new_request) begin
            lcc_pending_valid_q[c] <= 1'b1;
            lcc_pending_req_q[c]   <= lcc_if[c].request;
          end
        end
      end
    end
  endgenerate

  // Decide next request to be pushed into the FIFO
  assign ceu_pending_any = |ceu_pending_valid_q;

  // Isolate the least significant '1' in ceu_pending_valid_q
  assign ceu_grant_oh =
      gct_req_fifo_if.full ? '0 :
      (ceu_pending_valid_q & (~ceu_pending_valid_q + LSB_ONE));

  // Isolate the least significant '1' in lcc_pending_valid_q
  assign lcc_grant_oh =
      (gct_req_fifo_if.full || ceu_pending_any) ? '0 :
      (lcc_pending_valid_q & (~lcc_pending_valid_q + LSB_ONE));

  assign ceu_pending_to_fifo = ceu_grant_oh;
  assign lcc_pending_to_fifo = lcc_grant_oh;

  assign gct_req_fifo_if.push = |{ceu_grant_oh, lcc_grant_oh};
  assign gct_req_fifo_if.potential_push = gct_req_fifo_if.push;

  always_comb begin
    gct_req_fifo_if.data_in = '0;

    for (int unsigned c = 0; c < NUM_CORES; c++) begin
      if (ceu_grant_oh[c]) begin
        gct_req_fifo_if.data_in.src_core_oh    = '0;
        gct_req_fifo_if.data_in.src_core_oh[c] = 1'b1;
        gct_req_fifo_if.data_in.src_is_ceu     = 1'b1;
        gct_req_fifo_if.data_in.request        = ceu_pending_req_q[c];
      end

      if (lcc_grant_oh[c]) begin
        gct_req_fifo_if.data_in.src_core_oh    = '0;
        gct_req_fifo_if.data_in.src_core_oh[c] = 1'b1;
        gct_req_fifo_if.data_in.src_is_ceu     = 1'b0;
        gct_req_fifo_if.data_in.request        = lcc_pending_req_q[c];
      end
    end
  end

  cva5_fifo #(
      .DATA_TYPE (gct_fifo_entry_t),
      .FIFO_DEPTH(GCT_FIFO_DEPTH)
  ) gct_req_fifo (
      .clk (clk),
      .rst (rst),
      .fifo(gct_req_fifo_if)
  );

  // Engine
  assign gct_req_fifo_if.pop = (gct_state_q == GCT_IDLE) && gct_req_fifo_if.valid;

  // Response management
  generate
    for (genvar c = 0; c < NUM_CORES; c++) begin : gen_response_router

      logic ceu_done;
      logic lcc_done;

      assign ceu_done =
          (gct_state_q == GCT_RESP) &&
          current_entry_q.src_is_ceu &&
          current_entry_q.src_core_oh[c];

      assign lcc_done =
          (gct_state_q == GCT_RESP) &&
          !current_entry_q.src_is_ceu &&
          current_entry_q.src_core_oh[c];

      assign ceu_if[c].done = ceu_done;
      assign lcc_if[c].done = lcc_done;

      assign ceu_if[c].response = ceu_done ? response_q : '0;
      assign lcc_if[c].response = lcc_done ? response_q : '0;

    end
  endgenerate

  always_comb begin
    gct_state_d     = gct_state_q;
    current_entry_d = current_entry_q;
    response_d      = response_q;

    for (int unsigned i = 0; i < GCT_ENTRIES; i++) begin
      cap_table_d[i] = cap_table_q[i];
    end

    derive_parent_idx = current_entry_q.request.cap_idx;
    derive_parent_entry = cap_table_q[derive_parent_idx];

    derive_child_idx_ext =
        CSIZE_W'(derive_parent_idx) +
        derive_parent_entry.cfree -
        current_entry_q.request.child_csize;

    derive_child_idx = derive_child_idx_ext[CAP_IDX_W-1:0];

    derive_child_entry = '0;

    derive_child_end = current_entry_q.request.child_base + current_entry_q.request.child_size;

    derive_parent_end = derive_parent_entry.base + derive_parent_entry.size;

    case (gct_state_q)

      GCT_IDLE: begin
        if (gct_req_fifo_if.valid) begin
          current_entry_d = gct_req_fifo_if.data_out;
          gct_state_d     = GCT_EXEC;
        end
      end

      GCT_EXEC: begin
        response_d  = '0;
        gct_state_d = GCT_RESP;

        // Common capability checks
        if (derive_parent_entry.owner_pid == INVALID_PID) begin
          response_d.error = GCT_ERR_INVALID;
        end else if (derive_parent_entry.owner_pid != current_entry_q.request.caller_pid) begin
          response_d.error = GCT_ERR_OWNER;
        end else begin
          response_d.error = GCT_ERR_NONE;
        end

        case (current_entry_q.request.op)

          GCT_OP_LOOKUP: begin
            if (response_d.error == GCT_ERR_NONE) begin
              response_d.metadata = entry_to_metadata(derive_parent_entry);
            end
          end

          GCT_OP_DERIVE: begin
            if (response_d.error == GCT_ERR_NONE) begin

              // Bad arguments
              if (
                  (current_entry_q.request.child_csize == '0) ||
                  (current_entry_q.request.child_owner_pid == INVALID_PID)
              ) begin
                response_d.error = GCT_ERR_BAD_ARG;

                // Bounds
              end else if (
                  (derive_child_end <= current_entry_q.request.child_base) ||
                  (current_entry_q.request.child_base < derive_parent_entry.base) ||
                  (derive_child_end > derive_parent_end)
              ) begin
                response_d.error = GCT_ERR_BOUNDS;

                // Available space for the child
              end else if (derive_parent_entry.cfree <= current_entry_q.request.child_csize) begin
                response_d.error = GCT_ERR_NO_SPACE;

                // Permissions
              end else if (
                  ((derive_parent_entry.permissions & current_entry_q.request.child_permissions) !=
                    current_entry_q.request.child_permissions) ||
                  !valid_permissions(
                      current_entry_q.request.child_permissions
                  )) begin
                response_d.error = GCT_ERR_PERM;

                // Valid destination idx
              end else if (derive_child_idx_ext >= CSIZE_W'(GCT_ENTRIES)) begin
                response_d.error = GCT_ERR_BAD_ARG;

                // Destination slot must be free
              end else if (cap_table_q[derive_child_idx].owner_pid != INVALID_PID) begin
                response_d.error = GCT_ERR_INVALID;

              end else begin
                derive_child_entry.owner_pid = current_entry_q.request.child_owner_pid;
                derive_child_entry.base = current_entry_q.request.child_base;
                derive_child_entry.size = current_entry_q.request.child_size;
                derive_child_entry.permissions = current_entry_q.request.child_permissions;
                derive_child_entry.cfree = current_entry_q.request.child_csize;
                derive_child_entry.csize = current_entry_q.request.child_csize;

                cap_table_d[derive_parent_idx].cfree =
                    derive_parent_entry.cfree - current_entry_q.request.child_csize;

                cap_table_d[derive_child_idx] = derive_child_entry;

                response_d.error = GCT_ERR_NONE;
                response_d.child_idx = derive_child_idx;
                response_d.metadata = entry_to_metadata(derive_child_entry);
              end
            end
          end

          GCT_OP_DELETE: begin
            if (response_d.error == GCT_ERR_NONE) begin
              if (current_entry_q.request.cap_idx == '0) begin
                response_d.error = GCT_ERR_BAD_ARG;
              end else begin
                cap_table_d[current_entry_q.request.cap_idx] = '0;
              end
            end
          end
          // GCT_OP_REVOKE: ...

          default: begin
            response_d.error = GCT_ERR_OP;
          end

        endcase
      end

      GCT_RESP: begin
        gct_state_d = GCT_IDLE;
      end

      default: begin
        gct_state_d = GCT_IDLE;
      end

    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      gct_state_q     <= GCT_IDLE;
      current_entry_q <= '0;
      response_q      <= '0;
    end else begin
      gct_state_q     <= gct_state_d;
      current_entry_q <= current_entry_d;
      response_q      <= response_d;
    end
  end

  generate
    for (genvar i = 0; i < GCT_ENTRIES; i++) begin : gen_cap_table_ff

      always_ff @(posedge clk) begin
        if (rst) begin
          if (i == 0) begin
            cap_table_q[i] <= ROOT_CAPABILITY;
          end else begin
            cap_table_q[i] <= '0;
          end
        end else begin
          cap_table_q[i] <= cap_table_d[i];
        end
      end

    end
  endgenerate
endmodule












