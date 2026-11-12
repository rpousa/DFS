# /*
#  * Licensed to the OpenAirInterface (OAI) Software Alliance under one or more
#  * contributor license agreements.  See the NOTICE file distributed with
#  * this work for additional information regarding copyright ownership.
#  * The OpenAirInterface Software Alliance licenses this file to You under
#  * the OAI Public License, Version 1.1  (the "License"); you may not use this file
#  * except in compliance with the License.
#  * You may obtain a copy of the License at
#  *
#  *      http://www.openairinterface.org/?page_id=698
#  *
#  * Unless required by applicable law or agreed to in writing, software
#  * distributed under the License is distributed on an "AS IS" BASIS,
#  * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  * See the License for the specific language governing permissions and
#  * limitations under the License.
#  *-------------------------------------------------------------------------------
#  * For more information about the OpenAirInterface (OAI) Software Alliance:
#  *      contact@openairinterface.org
#  */

"""
Common definitions shared between CIR generator, loader, and emitter.
"""

import struct

MODEL_NAME = ["TDL-A", "TDL-B", "TDL-C", "TDL-D", "TDL-E"]
MODEL_TO_ID = {name: i for i, name in enumerate(MODEL_NAME)}

PKG_HDR_FMT = "<4sII"
ENT_FMT = "<QH H H I I d d f f f f f f I Q Q"
PKG_HDR_SIZE = struct.calcsize(PKG_HDR_FMT)
ENT_SIZE = struct.calcsize(ENT_FMT)

PAIR_ORDER_TX_MAJOR_RX_MINOR = 0

MAX_L = 8
