// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package Axi4BusesDefines;

import FIFO::*;
import GetPut::*;
import Connectable::*;
import DefaultValue::*;
import Axi4Utilities::*;

export DefaultValue::*;
export Axi4Utilities::*;
export Axi4BusesDefines::*;

/* HBM AXI memory bus
 *  ID: 6-bit, can be set to all zeros if not used
 *  Address width: 33-bit, 29-bit (i.e. 512MB) space for each channel
 *  Data width: 512-bit or 256-bit (if the design can run at 400MHz)
 *  Burst length width: 8-bit, however burst shall not be more than 8 beats (0x8)
 */
`define HBM_AXI_PRMS    6, 33, 512, 8, 0
`define HBM_AXI_RR      HbmTlmReq_t, HbmTlmResp_t

typedef TLMRequest      #(`HBM_AXI_PRMS)    HbmTlmReq_t;
typedef TLMResponse     #(`HBM_AXI_PRMS)    HbmTlmResp_t;
typedef TLMSendIFC      #(`HBM_AXI_RR)      HbmTlmSendIfc;
typedef TLMRecvIFC      #(`HBM_AXI_RR)      HbmTlmRecvIfc;
typedef Axi4RdWrMaster  #(`HBM_AXI_PRMS)    HbmAxiMasterIfc;
typedef Axi4RdWrSlave   #(`HBM_AXI_PRMS)    HbmAxiSlaveIfc;
typedef Axi4RdWrMasterXActorIFC #(`HBM_AXI_RR, `HBM_AXI_PRMS)   HbmMstXtrIfc;
typedef Axi4RdWrSlaveXActorIFC  #(`HBM_AXI_RR, `HBM_AXI_PRMS)   HbmSlvXtrIfc;
typedef RequestDescriptor #(`HBM_AXI_PRMS)  HbmTlmReqDesc_t;

/* DDR4 AXI memory bus (same params as HBM) */
typedef HbmTlmReq_t     DdrTlmReq_t;
typedef HbmTlmResp_t    DdrTlmResp_t;
typedef HbmTlmSendIfc   DdrTlmSendIfc;
typedef HbmTlmRecvIfc   DdrTlmRecvIfc;
typedef HbmAxiMasterIfc DdrAxiMasterIfc;
typedef HbmAxiSlaveIfc  DdrAxiSlaveIfc;
typedef HbmMstXtrIfc    DdrMstXtrIfc;
typedef HbmSlvXtrIfc    DdrSlvXtrIfc;
typedef HbmTlmReqDesc_t DdrTlmReqDesc_t;

/* XDMA Host DMA-Bypass AXI memory bus
 *  ID: 4-bit, can be ignored if not used
 *  Address width: 64-bit
 *  Data width: 512-bit
 *  Burst length width: 8-bit
 */
`define XDMAB_AXI_PRMS    4, 64, 512, 8, 0
`define XDMAB_AXI_RR      XdmaBypTlmReq_t, XdmaBypTlmResp_t

typedef TLMRequest      #(`XDMAB_AXI_PRMS)      XdmaBypTlmReq_t;
typedef TLMResponse     #(`XDMAB_AXI_PRMS)      XdmaBypTlmResp_t;
typedef RequestDescriptor #(`XDMAB_AXI_PRMS)    XdmaBypTlmReqDesc_t;
typedef TLMSendIFC      #(`XDMAB_AXI_RR)        XdmaBypTlmSendIfc;
typedef TLMRecvIFC      #(`XDMAB_AXI_RR)        XdmaBypTlmRecvIfc;
typedef Axi4RdWrMaster  #(`XDMAB_AXI_PRMS)      XdmaBypAxiMasterIfc;
typedef Axi4RdWrSlave   #(`XDMAB_AXI_PRMS)      XdmaBypAxiSlaveIfc;
typedef Axi4RdWrMasterXActorIFC #(`XDMAB_AXI_RR, `XDMAB_AXI_PRMS)   XdmaBypMstXtrIfc;
typedef Axi4RdWrSlaveXActorIFC  #(`XDMAB_AXI_RR, `XDMAB_AXI_PRMS)   XdmaBypSlvXtrIfc;

endpackage : Axi4BusesDefines
