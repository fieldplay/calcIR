src     = calcIR.cu
exes    = calcIR.exe
exed    = calcIR_d.exe
exeseuler= calcIReuler.exe
NVCC    = nvcc
INC     = -I$(CUDADIR)/include -I$(MKLROOT)/include -I$(MAGMADIR)/include
FLAGS	= -Xcompiler "-fPIC -Wall -Wno-unused-function" -DMKL_ILP64 -Wno-deprecated-gpu-targets
LIBS    = -lmkl_gf_ilp64 -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl -lcufft -lmagma -lxdrfile
LIBDIRS = -L/opt/intel/mkl/lib/intel64 -L/user/local/cuda/lib64 -L/usr/local/magma/lib
INCDIRS = -I/opt/intel/mkl/include -I/user/local/cuda/include -I/user/local/magma/include


all: ${exes} ${exed} ${exeseuler}

${exes}: ${src}
	$(NVCC) $(src) -o $(exes) $(FLAGS) $(LIBDIRS) $(LIBS) $(INCDIRS)

${exeseuler}: ${src}
	$(NVCC) $(src) -o $(exeseuler) $(FLAGS) $(LIBDIRS) $(LIBS) $(INCDIRS) -DUSE_EULER=1


${exed}: ${src}
	$(NVCC) $(src) -o $(exed) $(FLAGS) $(LIBDIRS) $(LIBS) $(INCDIRS) -DUSE_DOUBLES=1

clean:
	rm calcIR.exe
	rm calcIR_d.exe
