package capability_types;

  parameter int unsigned NUM_CORES = 1;
  parameter int unsigned GCT_ENTRIES = 128;
  parameter int unsigned GCT_FIFO_DEPTH = 8;
  parameter int unsigned PID_W = 8;
  parameter int unsigned ADDR_W = 32;
  parameter int unsigned PERM_W = 3;  // {X, W, R}
  localparam int unsigned CAP_IDX_W = (GCT_ENTRIES <= 2) ? 1 : $clog2(GCT_ENTRIES);
  localparam int unsigned CSIZE_W = (GCT_ENTRIES <= 2) ? 1 : $clog2(GCT_ENTRIES + 1);
  localparam logic [PERM_W-1:0] PERM_NONE = 3'b000;
  localparam logic [PERM_W-1:0] R_PERM = 3'b001;
  localparam logic [PERM_W-1:0] W_PERM = 3'b010;
  localparam logic [PERM_W-1:0] X_PERM = 3'b100;
  localparam logic [PID_W-1:0] ROOT_OWNER_PID = PID_W'(1);
  localparam logic [ADDR_W-1:0] ROOT_BASE = '0;
  localparam logic [ADDR_W-1:0] ROOT_SIZE = '1;
  localparam logic [PERM_W-1:0] ROOT_PERMISSIONS = '1;
  localparam logic [NUM_CORES-1:0] LSB_ONE = 'd1;
  localparam logic [PID_W-1:0] INVALID_PID = '0;



  typedef enum logic [2:0] {
    GCT_OP_LOOKUP  = 3'd0,
    GCT_OP_PRELOAD = 3'd1,
    GCT_OP_DERIVE  = 3'd2,
    GCT_OP_DELETE  = 3'd3,
    GCT_OP_REVOKE  = 3'd4
  } gct_op_t;

  typedef enum logic [3:0] {
    GCT_ERR_NONE     = 4'd0,
    GCT_ERR_INVALID  = 4'd1,
    GCT_ERR_OWNER    = 4'd2,
    GCT_ERR_PERM     = 4'd3,
    GCT_ERR_BOUNDS   = 4'd4,
    GCT_ERR_NO_SPACE = 4'd5,
    GCT_ERR_BAD_ARG  = 4'd6,
    GCT_ERR_OP       = 4'd7
  } gct_error_t;

  typedef struct packed {
    logic [PID_W-1:0]   owner_pid;
    logic [ADDR_W-1:0]  base;
    logic [ADDR_W-1:0]  size;
    logic [PERM_W-1:0]  permissions;
    logic [CSIZE_W-1:0] cfree;
    logic [CSIZE_W-1:0] csize;
  } gct_entry_t;

  localparam gct_entry_t ROOT_CAPABILITY = '{
      default: '0,
      owner_pid: ROOT_OWNER_PID,
      base: ROOT_BASE,
      size: ROOT_SIZE,
      permissions: ROOT_PERMISSIONS,
      cfree: CSIZE_W'(GCT_ENTRIES),
      csize: CSIZE_W'(GCT_ENTRIES)
  };

  typedef struct packed {
    logic [PID_W-1:0]  owner_pid;
    logic [ADDR_W-1:0] base;
    logic [ADDR_W-1:0] size;
    logic [PERM_W-1:0] permissions;
  } cap_metadata_t;

  typedef struct packed {
    gct_op_t op;

    logic [PID_W-1:0] caller_pid;

    logic [CAP_IDX_W-1:0] cap_idx;

    //Only used for derive
    logic [PID_W-1:0]   child_owner_pid;
    logic [ADDR_W-1:0]  child_base;
    logic [ADDR_W-1:0]  child_size;
    logic [PERM_W-1:0]  child_permissions;
    logic [CSIZE_W-1:0] child_csize;
  } gct_request_t;

  typedef struct packed {
    gct_error_t error;
    cap_metadata_t metadata;
    logic [CAP_IDX_W-1:0] child_idx;
  } gct_response_t;

  typedef struct packed {
    logic [NUM_CORES-1:0] src_core_oh;
    logic                 src_is_ceu;
    gct_request_t         request;
  } gct_fifo_entry_t;

  typedef enum logic [1:0] {
    GCT_IDLE,
    GCT_EXEC,
    GCT_RESP

  } gct_state_t;

endpackage


