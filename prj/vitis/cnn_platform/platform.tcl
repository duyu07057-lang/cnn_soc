# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct D:\Xilinx\zynq7020\cnn_soc\prj\vitis\cnn_platform\platform.tcl
# 
# OR launch xsct and run below command.
# source D:\Xilinx\zynq7020\cnn_soc\prj\vitis\cnn_platform\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {cnn_platform}\
-hw {D:\Xilinx\zynq7020\cnn_soc\prj\vitis\cnn_system.xsa}\
-proc {ps7_cortexa9_0} -os {standalone} -fsbl-target {psu_cortexa53_0} -out {D:/Xilinx/zynq7020/cnn_soc/prj/vitis}

platform write
platform generate -domains 
platform active {cnn_platform}
domain active {zynq_fsbl}
bsp reload
domain active {standalone_domain}
bsp reload
platform generate
