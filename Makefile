#
# Use Altera ModelSim:
#   module load modelsim/18.1
#
SOURCES         = zpu_core_defines.v \
                  zpu_core_rom.v \
                  zpu_core.v

all:            work

clean:
		rm -rf *.o *.vcd work

work:           $(SOURCES)
		vlib work
		vlog -sv $(SOURCES)

run:            work
		vsim -c -l run.log -do 'run 100000us; quit' testbench

view:
		gtkwave testbench.vcd databus.gtkw
