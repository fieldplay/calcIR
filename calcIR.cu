/*This is my first attempt to port my python ir program to cuda. 
 * It currently suffers from **very** slow excecution in python. 
 * I'm going to try to port it to cuda c */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <xdrfile/xdrfile.h>
#include <xdrfile/xdrfile_xtc.h>
#include "calcIR.h"

#include "magma_v2.h"
#include <cufft.h>

#define HBAR 5.30887         // in cm-1 * ps
#define PI   3.14159265359


int main()
{

    // ***              Variable Declaration            *** //
    // **************************************************** //

    // User input
    // TODO: make to get from user instead of hardcode
    const char  *gmxf         = (const char *)"./n216/traj_comp.xtc"; // trajectory file
    const int   frame0        = 0;      // beginning frame to read
    const int   framelast     = 1000;   // last frame to read
    const int   natom_mol     = 4;      // Atoms per water molecule  :: MODEL DEPENDENT
    const int   nchrom_mol    = 2;      // Chromophores per molecule :: TWO for stretch -- ONE for bend
    const float t1            = 0.260;  // relaxation time
    const float avef          = 3400.0; // the approximate average stretch frequency to get rid of high frequency oscillations in the time correlation function
    const float dt            = 0.010;  // dt in ps
    const int   omegaStart    = 2800;   // starting frequency for spectral density
    const int   omegaStop     = 4000;   // ending frequency for spectral density
    const int   omegaStep     = 5 ;     // resolution for spectral density


    // Some useful variables and constants
    int               natoms, nmol, frame, nchrom;
    const int         nframes     = framelast - frame0;                         // number of frames
    const int         ntcfpoints  = nframes;                                    // number of points for the time correlation function
    const int         ntcfpointsR = (ntcfpoints - 1)*2;                         // number of points for the real fourier transform
    const int         nomega      = ( omegaStop - omegaStart ) / omegaStep + 1; // number of frequencies for the spectral density

    // Trajectory stuff for the CPU
    rvec        *x;                     // Position vector
    matrix      box;                    // Box vectors
    float       boxl, gmxtime, prec;    // Box lengths, time at current frame, precision of xtf file
    int         step;                   // The current step number

    // Some variables for the GPU
    rvec                *x_d;                       // positions
    float               *mux_d, *muy_d, *muz_d;     // transition dipole moments
    magmaFloatComplex   *cmux_d, *cmuy_d, *cmuz_d;  // complex versions of the transition dipole moment
    magmaFloatComplex   *tmpmu_d;                   // to sum all polarizations
    float               *MUX_d, *MUY_d, *MUZ_d;     // transition dipole moments in the eigen basis
    float               *eproj_d;                   // the electric field projected along the oh bonds
    float               *kappa_d;                   // the hamiltonian on the GPU
    const int           blockSize = 128;            // The number of threads to launch per block

    // magma variables for ssyevr
    float       aux_work[1];            // To get optimal size of lwork
    magma_int_t aux_iwork[1], info;     // To get optimal liwork, and return info
    magma_int_t ldkappa, lwork, liwork; // Leading dim of kappa, sizes of work arrays
    magma_int_t *iwork;                 // Work array
    float       *work;                  // Work array
    float       *w   ;                  // Eigenvalues
    float       *wA  ;                  // Work array
    // real_Double_t gpu_time;

    // magma variables for gemv
    magma_queue_t   queue;

    // variables for spectrum calculations
    float       *w_d;                   // Eigenvalues on the GPU
    float       *omega, *omega_d;       // Frequencies on CPU and GPU
    float       *Sw, *Sw_d;             // Spectral density on CPU and GPU

    // variables for TCF
    magmaFloatComplex *F, *F_d;             // F matrix on CPU and GPU
    magmaFloatComplex *propeig, *propeig_d; // Propigator matrix on CPU and GPU
    magmaFloatComplex *proploc_d, *ckappa_d;// Propigator matrix in the local basis and a complex version of kappa
    magmaFloatComplex tcfx, tcfy, tcfz;     // Time correlation function, polarized
    magmaFloatComplex dcy, tcftmp;          // Decay constant and a temporary variable for the tcf
    magmaFloatComplex *tcf, *tcf_d;         // Time correlation function
    float             *Ftcf, *Ftcf_d;       // Fourier transformed time correlation function
    float             *time;                // Time array for tcf
    float             arg;                  // argument of exponential

    // For fft on gpu
    cufftHandle       plan;

    // **************************************************** //
    // ***         End  Variable Declaration            *** //


    



    // ***          Begin main routine                  *** //
    // **************************************************** //

    // Open trajectory file and get info about the systeem
    printf("Will read the trajectory from: %s.\n",gmxf);
    XDRFILE *trj = xdrfile_open( gmxf, "r" ); 

    read_xtc_natoms( (char *)gmxf, &natoms);
    nmol         = natoms / natom_mol;
    nchrom       = nmol * nchrom_mol;
    ldkappa      = (magma_int_t) nchrom;


    printf("Found %d atoms and %d molecules.\n",natoms, nmol);
    printf("Found %d chromophores.\n",nchrom);




    // ***              MEMORY ALLOCATION               *** //
    // **************************************************** //

    // determine the number of blocks to launch on the gpu 
    // each thread takes care of one chromophore
    const int numBlocks = (nchrom+blockSize-1)/blockSize;
    
    // Initialize magma math library and initialize queue
    magma_init();
    magma_queue_create( 0, &queue ); 

    // allocate memory for arrays on the CPU
    x       = (rvec*)               malloc( natoms    *    sizeof(x[0] ));
    omega   = (float *)             malloc( nomega    *    sizeof(float));
    Sw      = (float *)             malloc( nomega    *    sizeof(float));
    time    = (float *)             malloc( ntcfpoints*    sizeof(float));
    Ftcf    = (float *)             malloc( ntcfpointsR*   sizeof(float*));
    tcf     = (magmaFloatComplex *) malloc( ntcfpoints*    sizeof(magmaFloatComplex));
    F       = (magmaFloatComplex *) calloc( nchrom*nchrom, sizeof(magmaFloatComplex));
    propeig = (magmaFloatComplex *) calloc( nchrom*nchrom, sizeof(magmaFloatComplex));
    
    // allocate memory for arrays on the GPU
    cudaMalloc( &x_d     , natoms*sizeof(x[0]));
    cudaMalloc( &mux_d   , nchrom*sizeof(float));
    cudaMalloc( &muy_d   , nchrom*sizeof(float));
    cudaMalloc( &muz_d   , nchrom*sizeof(float));
    cudaMalloc( &MUX_d   , nchrom*sizeof(float));
    cudaMalloc( &MUY_d   , nchrom*sizeof(float));
    cudaMalloc( &MUZ_d   , nchrom*sizeof(float));
    cudaMalloc( &omega_d , nomega*sizeof(float));
    cudaMalloc( &Sw_d    , nomega*sizeof(float));
    cudaMalloc( &Ftcf_d  , ntcfpointsR*sizeof(float));
    cudaMalloc( &cmux_d  , nchrom*sizeof(magmaFloatComplex));
    cudaMalloc( &cmuy_d  , nchrom*sizeof(magmaFloatComplex));
    cudaMalloc( &cmuz_d  , nchrom*sizeof(magmaFloatComplex));
    cudaMalloc( &tmpmu_d , nchrom*sizeof(magmaFloatComplex));

    magma_smalloc( &eproj_d     , nchrom );
    magma_smalloc( &kappa_d     , ldkappa*nchrom);
    magma_cmalloc( &ckappa_d    , nchrom*nchrom);
    magma_cmalloc( &F_d         , nchrom*nchrom);
    magma_cmalloc( &propeig_d   , nchrom*nchrom);
    magma_cmalloc( &proploc_d   , nchrom*nchrom);
    magma_smalloc( &w_d         , nchrom );
    magma_cmalloc( &tcf_d       , ntcfpoints);


    // ***          END MEMORY ALLOCATION               *** //
    // **************************************************** //





    // **************************************************** //
    // ***         MAIN LOOP OVER TRAJECTORY            *** //
    for ( frame=frame0; frame<framelast; frame++ ){




        // ***          Get Info About The System           *** //

        // read the current frame from the trajectory file and copy to device memory
        read_xtc( trj, natoms, &step, &gmxtime, box, x, &prec );
        cudaMemcpy( x_d, x, natoms*sizeof(x[0]), cudaMemcpyHostToDevice );
        boxl = box[0][0];   // assume a square box NOTE: CHANGE IF NOT THE CASE


        // launch kernel to calculate the electric field projection along OH bonds
        get_eproj_GPU <<<numBlocks,blockSize>>> ( x_d, boxl, natoms, natom_mol, nchrom, nchrom_mol, nmol, eproj_d );

        // launch kernel to build the exciton Hamiltonian
        get_kappa_GPU <<<numBlocks,blockSize>>> ( x_d, boxl, natoms, natom_mol, nchrom, nchrom_mol, nmol, eproj_d, 
                                                  kappa_d, mux_d, muy_d, muz_d );

        // ***          Done getting System Info            *** //




        // ***          Diagonalize the Hamiltonian         *** //

        // if the first time, query for optimal workspace dimensions
        if ( frame == frame0)
        {
            magma_ssyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, NULL, ldkappa, 
                              NULL, NULL, (magma_int_t) nchrom, aux_work, -1, aux_iwork, -1, &info );

            lwork   = (magma_int_t) aux_work[0];
            liwork  = aux_iwork[0];

            // make space for work arrays and eigenvalues and other stuff
            magma_smalloc_cpu   ( &w  , (magma_int_t) nchrom );
            magma_smalloc_pinned( &wA , (magma_int_t) nchrom*ldkappa );
            magma_smalloc_pinned( &work , lwork  );
            magma_imalloc_cpu   ( &iwork, liwork );
        }
        magma_ssyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, kappa_d, ldkappa,
                          w, wA, ldkappa, work, lwork, iwork, liwork, &info );

        // ***          Done with the Diagonalization       *** //




        // ***              The Spectral Density            *** //

        if ( frame == frame0 ){

            // project the transition dipole moments onto the eigenbasis
            // MU_d = kappa_d**T x mu_d 
            magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         1.0, kappa_d, ldkappa, mux_d, 1, 0.0, MUX_d, 1, queue);
            magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         1.0, kappa_d, ldkappa, muy_d, 1, 0.0, MUY_d, 1, queue);
            magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         1.0, kappa_d, ldkappa, muz_d, 1, 0.0, MUZ_d, 1, queue);

            // Define the spectral range of interest and initialize spectral arrays
            for (int i = 0; i < nomega; i++)
            {
                omega[i] = (float) (omegaStart + omegaStep*i); 
                Sw[i]    = 0.0;
            }

            // Copy relevant variables to device memory
            cudaMemcpy( omega_d, omega, nomega*sizeof(float), cudaMemcpyHostToDevice );
            cudaMemcpy( w_d    , w    , nchrom*sizeof(float), cudaMemcpyHostToDevice );
            cudaMemcpy( Sw_d   , Sw   , nomega*sizeof(float), cudaMemcpyHostToDevice );

            // calculate the spectral density on the GPU and copy back to the CPU
            get_spectral_density<<<numBlocks,blockSize>>>( w_d, MUX_d, MUY_d, MUZ_d, omega_d, Sw_d, 
                                                            nomega, nchrom, t1 );
            cudaMemcpy( Sw, Sw_d, nomega*sizeof(float), cudaMemcpyDeviceToHost );
        }

        // ***           Done the Spectral Density          *** //




        // ***           Time Correlation Function          *** //

        // cast variables to complex to calculate time correlation function (which is complex)
        cast_to_complex_GPU <<<numBlocks,blockSize>>> ( kappa_d, ckappa_d, nchrom*nchrom );
        cast_to_complex_GPU <<<numBlocks,blockSize>>> ( mux_d  , cmux_d  , nchrom        );
        cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muy_d  , cmuy_d  , nchrom        );
        cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muz_d  , cmuz_d  , nchrom        );


        // First calculate the propigation matrix in the local basis
        if ( frame == frame0 )
        {
            // initialize the F matrix at t=0 to the unit matrix
            for ( int i = 0; i < nchrom; i ++ )
            {
                // NOTE: off diagonal elements were zeroed on allocation using calloc
                F[ i*nchrom + i] = MAGMA_C_MAKE(1.0,0.0);
            }
            // copy the F matrix to device memory -- after initialization, won't need back in host memory
            cudaMemcpy( F_d, F, nchrom*nchrom*sizeof(magmaFloatComplex), cudaMemcpyHostToDevice );
        }
        else
        {
            // build the propigator
            for ( int i = 0; i < nchrom; i++ )
            {
                // note off diagonal elements were zeroed on allocation using calloc and they shouldnt change
                // but be careful here... P = exp(iwt/hbar)
                arg   = (w[i] - avef)* dt / HBAR;
                propeig[ i*nchrom + i ] = MAGMA_C_MAKE( cos(arg), sin(arg) );
            }

            // copy the propigator to the gpu and convert to the local basis                
            cudaMemcpy( propeig_d, propeig, nchrom*nchrom*sizeof(magmaFloatComplex), cudaMemcpyHostToDevice );

            // ckappa_d * propeig_d = proploc_d
            magma_cgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         (magma_int_t) nchrom, MAGMA_C_ONE, ckappa_d, ldkappa, propeig_d, ldkappa,
                          MAGMA_C_ZERO, proploc_d, ldkappa, queue );

            // proploc_d * ckappa_d **T = proploc_d
            magma_cgemm( MagmaNoTrans, MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         (magma_int_t) nchrom, MAGMA_C_ONE, proploc_d, ldkappa, ckappa_d, ldkappa, 
                         MAGMA_C_ZERO, proploc_d, ldkappa, queue );

            // propigate the F matrix in the local basis
            // proploc_d * F = F
            magma_cgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                         (magma_int_t) nchrom, MAGMA_C_ONE, proploc_d, ldkappa, F_d, ldkappa, 
                         MAGMA_C_ZERO, F_d, ldkappa, queue );
        }


        // now calculate mFm for x y and z components
        // F_d * cmux_d = tmpmu_d
        magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, ldkappa,
                     cmux_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
        // tcfx = cmux_d**T * tmpmu_d
        tcfx = magma_cdotu( (magma_int_t) nchrom, cmux_d, 1, tmpmu_d, 1, queue );

        // F_d * cmuy_d = tmpmu_d
        magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, ldkappa,
                     cmuy_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
        // tcfy = cmuy_d**T * tmpmu_d
        tcfy = magma_cdotu( (magma_int_t) nchrom, cmuy_d, 1, tmpmu_d, 1, queue );

        // F_d * cmuz_d = tmpmu_d
        magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, ldkappa,
                     cmuz_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
        // tcfz = cmuz_d**T * tmpmu_d
        tcfz = magma_cdotu( (magma_int_t) nchrom, cmuz_d, 1, tmpmu_d, 1, queue );


        // save the variables to print later and multiply by the decay
        time[frame]           = dt * frame;
        tcftmp                = MAGMA_C_ADD( tcfx  , tcfy );
        tcftmp                = MAGMA_C_ADD( tcftmp, tcfz );
        dcy                   = MAGMA_C_MAKE(exp( -1.0 * (frame-frame0) * dt / ( 2.0 * t1 )), 0);
        tcf[frame]            = MAGMA_C_MUL( tcftmp, dcy );

        // ***        Done with Time Correlation            *** //

    }

    // fourier transform the time correlation function on the GPU
    cufftPlan1d( &plan, ntcfpoints, CUFFT_C2R, 1);
    cudaMemcpy( tcf_d, tcf, ntcfpoints*sizeof(magmaFloatComplex), cudaMemcpyHostToDevice );
    cufftExecC2R( plan, tcf_d, Ftcf_d );
    cudaMemcpy( Ftcf, Ftcf_d, ntcfpointsR*sizeof(float), cudaMemcpyDeviceToHost );


    // write time correlation function
    // TODO:: allow user to define custom names
    FILE *rtcf = fopen("tcf_real.dat", "w");
    FILE *itcf = fopen("tcf_imag.dat", "w");
    for ( int i = 0; i < ntcfpoints; i++ )
    {
        fprintf( rtcf, "%e %e \n", time[i], MAGMA_C_REAL( tcf[i] ) );
        fprintf( itcf, "%e %e \n", time[i], MAGMA_C_IMAG( tcf[i] ) );
    }
    fclose( rtcf );
    fclose( itcf );

    // write the spectral density to file
    FILE *spec_density = fopen("spectral_density.dat", "w");
    for ( int i = 0; i < nomega; i++)
    {
        fprintf(spec_density, "%e %e\n", omega[i], Sw[i]);
    }
    fclose(spec_density);

    // Write the absorption lineshape... Since the C2R transform is inverse by default, the frequencies have to be negated
    FILE *spec_lineshape = fopen("spectral_lineshape.dat", "w");
    float factor  = 2*PI*HBAR/(dt*ntcfpoints);  // conversion factor to give energy and correct intensity from FFT
    for ( int i = ntcfpoints/2; i < ntcfpoints; i++ ) // "negative" FFT frequencies
    {
        if ( -1*(i-ntcfpoints)*factor + avef <= (float) omegaStop  )
        {
            fprintf(spec_lineshape, "%e %e\n", -1*(i-ntcfpoints)*factor + avef, Ftcf[i]/(factor*ntcfpoints));
        }
    }
    for ( int i = 0; i < ntcfpoints / 2 ; i++)       // "positive" FFT frequencies
    {
        if ( -1*i*factor + avef >= (float) omegaStart)
        {
            fprintf(spec_lineshape, "%e %e\n", -1*i*factor + avef, Ftcf[i]/(factor*ntcfpoints));
        }
    }
    fclose(spec_lineshape);

    // free memory on the CPU and GPU and finalize magma library
    magma_queue_destroy( queue );

    free(x);
    free(omega);
    free(Sw);
    free(time);
    free(Ftcf);
    free(tcf);
    free(F);
    free(propeig);

    cudaFree(x_d);
    cudaFree(mux_d); 
    cudaFree(muy_d);
    cudaFree(muz_d);
    cudaFree(MUX_d); 
    cudaFree(MUY_d);
    cudaFree(MUZ_d);
    cudaFree(omega_d);
    cudaFree(Sw_d);
    cudaFree(Ftcf_d);
    cudaFree(cmux_d); 
    cudaFree(cmuy_d);
    cudaFree(cmuz_d);
    cudaFree(tmpmu_d);
 
    magma_free(eproj_d);
    magma_free(kappa_d);
    magma_free(ckappa_d);
    magma_free(F_d);
    magma_free(propeig_d);
    magma_free(proploc_d);
    magma_free(w_d);
    magma_free(tcf_d);

    magma_free_cpu(w);
    magma_free_cpu(iwork);
    magma_free_pinned( work );
    magma_free_pinned( wA );

    // final call to finalize magma math library
    magma_finalize();

    return 0;
}

/**********************************************************
   
   BUILD ELECTRIC FIELD PROJECTION ALONG OH BONDS
                    GPU FUNCTION

 **********************************************************/
__global__
void get_eproj_GPU( rvec *x, float boxl, int natoms, int natom_mol, int nchrom, int nchrom_mol, int nmol, float  *eproj )
{
    
    int n, m, i, j, istart, istride;
    int chrom;
    float mox[DIM];                     // oxygen position on molecule m
    float mx[DIM];                      // atom position on molecule m
    float nhx[DIM];                     // hydrogen position on molecule n of the current chromophore
    float nox[DIM];                     // oxygen position on molecule n
    float nohx[DIM];                    // the unit vector pointing along the OH bond for the current chromophore
    float dr[DIM];                      // the min image vector between two atoms
    float r;                            // the distance between two atoms 
    const float cutoff = 0.7831;        // the oh cutoff distance
    const float bohr_nm = 18.8973;      // convert from bohr to nanometer
    rvec efield;                        // the electric field vector

    istart  =   blockIdx.x * blockDim.x + threadIdx.x;
    istride =   blockDim.x * gridDim.x;

    // Loop over the chromophores belonging to the current thread
    for ( chrom = istart; chrom < nchrom; chrom += istride )
    {
        // calculate the molecule hosting the current chromophore 
        n = chrom / nchrom_mol;

        // initialize the electric field vector to zero at this chromophore
        efield[0]   =   0.;
        efield[1]   =   0.;
        efield[2]   =   0.;


        // ***          GET INFO ABOUT MOLECULE N HOSTING CHROMOPHORE       *** //
        //                      N IS OUR REFERENCE MOLECULE                     //
        // get the position of the hydrogen associated with the current stretch 
        // NOTE: I'm making some assumptions about the ordering of the positions, 
        // this can be changed if necessary for a more robust program
        // Throughout, I assume that the atoms are grouped into molecules and that
        // every 4th molecule starting at 0 (1, 2, 3) is OW (HW1, HW2, MW)
        if ( chrom % 2 == 0 ){      //HW1
            nhx[0]  = x[ n*natom_mol + 1 ][0];
            nhx[1]  = x[ n*natom_mol + 1 ][1];
            nhx[2]  = x[ n*natom_mol + 1 ][2];
        }
        else if ( chrom % 2 == 1 ){ //HW2
            nhx[0]  = x[ n*natom_mol + 2 ][0];
            nhx[1]  = x[ n*natom_mol + 2 ][1];
            nhx[2]  = x[ n*natom_mol + 2 ][2];
        }

        // The oxygen position
        nox[0]  = x[ n*natom_mol ][0];
        nox[1]  = x[ n*natom_mol ][1];
        nox[2]  = x[ n*natom_mol ][2];

        // The oh unit vector
        nohx[0] = minImage( nhx[0] - nox[0], boxl );
        nohx[1] = minImage( nhx[1] - nox[1], boxl );
        nohx[2] = minImage( nhx[2] - nox[2], boxl );
        r       = mag3(nohx);
        nohx[0] /= r;
        nohx[1] /= r;
        nohx[2] /= r;
        // ***          DONE WITH MOLECULE N                                *** //



        // ***          LOOP OVER ALL OTHER MOLECULES                       *** //
        for ( m = 0; m < nmol; m++ ){

            // skip the reference molecule
            if ( m == n ) continue;

            // get oxygen position on current molecule
            mox[0] = x[ m*natom_mol ][0];
            mox[1] = x[ m*natom_mol ][1];
            mox[2] = x[ m*natom_mol ][2];

            // find displacement between oxygen on m and hydrogen on n
            dr[0]  = minImage( mox[0] - nhx[0], boxl );
            dr[1]  = minImage( mox[1] - nhx[1], boxl );
            dr[2]  = minImage( mox[2] - nhx[2], boxl );
            r      = mag3(dr);

            // skip if the distance is greater than the cutoff
            if ( r > cutoff ) continue;

            // loop over all atoms in the current molecule and calculate the electric field 
            // (excluding the oxygen atoms since they have no charge)
            for ( i=1; i < natom_mol; i++ ){

                // position of current atom
                mx[0] = x[ m*natom_mol + i ][0];
                mx[1] = x[ m*natom_mol + i ][1];
                mx[2] = x[ m*natom_mol + i ][2];

                // the minimum image displacement between the reference hydrogen and the current atom
                // NOTE: this converted to bohr so the efield will be in au
                dr[0]  = minImage( nhx[0] - mx[0], boxl )*bohr_nm;
                dr[1]  = minImage( nhx[1] - mx[1], boxl )*bohr_nm;
                dr[2]  = minImage( nhx[2] - mx[2], boxl )*bohr_nm;
                r      = mag3(dr);

                // Add the contribution of the current atom to the electric field
                if ( i < 3  ){              // HW1 and HW2
                    for ( j=0; j < DIM; j++){
                        efield[j] += 0.52 * dr[j] / (r*r*r);
                    }
                }
                else if ( i == 3 ){         // MW (note the negative sign)
                    for ( j=0; j < DIM; j++){
                        efield[j] -= 1.04 * dr[j] / (r*r*r);
                    }
                }
            } // end loop over atoms in molecule m

        } // end loop over molecules m

        // project the efield along the OH bond to get the relevant value for the map
        eproj[chrom] = dot3( efield, nohx );

        // test looks good, everything appears to be ok
        // printf("chrom: %d, eproj %f \n", chrom, eproj[chrom]);

    } // end loop over reference chromophores

}

/**********************************************************
   
   BUILD HAMILTONIAN AND RETURN TRANSITION DIPOLE VECTOR
    FOR EACH CHROMOPHORE ON THE GPU

 **********************************************************/
__global__
void get_kappa_GPU( rvec *x, float boxl, int natoms, int natom_mol, int nchrom, int nchrom_mol, int nmol, 
                    float  *eproj, float  *kappa, float *mux, float *muy, float *muz)
{
    
    int n, m, istart, istride;
    int chromn, chromm;
    float mox[DIM];                         // oxygen position on molecule m
    float mhx[DIM];                         // atom position on molecule m
    float nhx[DIM];                         // hydrogen position on molecule n of the current chromophore
    float nox[DIM];                         // oxygen position on molecule n
    float noh[DIM];
    float moh[DIM];
    float nmu[DIM];
    float mmu[DIM];
    float mmuprime;
    float nmuprime;
    float dr[DIM];                          // the min image vector between two atoms
    float r;                                // the distance between two atoms 
    const float bohr_nm    = 18.8973;       // convert from bohr to nanometer
    const float cm_hartree = 2.1947463E5;   // convert from cm-1 to hartree
    float  En, Em;                           // the electric field projection
    float  xn, xm, pn, pm;                   // the x and p from the map
    float  wn, wm;                           // the energies

    istart  =   blockIdx.x * blockDim.x + threadIdx.x;
    istride =   blockDim.x * gridDim.x;

    // Loop over the chromophores belonging to the current thread and fill in kappa for that row
    for ( chromn = istart; chromn < nchrom; chromn += istride )
    {
        // calculate the molecule hosting the current chromophore 
        // and get the corresponding electric field at the relevant hydrogen
        n   = chromn / nchrom_mol;
        En  = eproj[chromn];

        // build the map
        wn  = 3760.2 - 3541.7*En - 152677.0*En*En;
        xn  = 0.19285 - 1.7261E-5 * wn;
        pn  = 1.6466  + 5.7692E-4 * wn;
        nmuprime = 0.1646 + 11.39*En + 63.41*En*En;

        // and calculate the location of the transition dipole moment
        // SEE calc_efield_GPU for assumptions about ordering of atoms
        nox[0]  = x[ n*natom_mol ][0];
        nox[1]  = x[ n*natom_mol ][1];
        nox[2]  = x[ n*natom_mol ][2];
        if ( chromn % 2 == 0 )       //HW1
        {
            nhx[0]  = x[ n*natom_mol + 1 ][0];
            nhx[1]  = x[ n*natom_mol + 1 ][1];
            nhx[2]  = x[ n*natom_mol + 1 ][2];
        }
        else if ( chromn % 2 == 1 )  //HW2
        {
            nhx[0]  = x[ n*natom_mol + 2 ][0];
            nhx[1]  = x[ n*natom_mol + 2 ][1];
            nhx[2]  = x[ n*natom_mol + 2 ][2];
        }

        // The OH unit vector
        noh[0] = minImage( nhx[0] - nox[0], boxl );
        noh[1] = minImage( nhx[1] - nox[1], boxl );
        noh[2] = minImage( nhx[2] - nox[2], boxl );
        r      = mag3(noh);
        noh[0] /= r;
        noh[1] /= r;
        noh[2] /= r;

        // The location of the TDM
        nmu[0] = minImage( nox[0] + 0.067 * noh[0], boxl );
        nmu[1] = minImage( nox[1] + 0.067 * noh[1], boxl );
        nmu[2] = minImage( nox[2] + 0.067 * noh[2], boxl );
        
        // and the TDM vector to return
        mux[chromn] = noh[0] * nmuprime * xn;
        muy[chromn] = noh[1] * nmuprime * xn;
        muz[chromn] = noh[2] * nmuprime * xn;
        // test by setting x to one // BE SURE TO REMOVE
        //mux[chromn] = 1.0;
        //muy[chromn] = 1.0;
        //muz[chromn] = 1.0;



        // Loop over all other chromophores
        for ( chromm = 0; chromm < nchrom; chromm ++ )
        {
            // calculate the molecule hosting the current chromophore 
            // and get the corresponding electric field at the relevant hydrogen
            m   = chromm / nchrom_mol;
            Em  = eproj[chromm];

            // also get the relevent x and p from the map
            wm  = 3760.2 - 3541.7*Em - 152677.0*Em*Em;
            xm  = 0.19285 - 1.7261E-5 * wm;
            pm  = 1.6466  + 5.7692E-4 * wm;
            mmuprime = 0.1646 + 11.39*Em + 63.41*Em*Em;

            // the diagonal energy
            if ( chromn == chromm )
            {
                // Note that this is a flattened 2d array
                kappa[chromn*nchrom + chromm]   =   wm; 
            }

            // intramolecular coupling
            else if ( m == n )
            {
                kappa[chromn*nchrom + chromm]   =  (-1361.0 + 27165*(En + Em))*xn*xm - 1.887*pn*pm;
            }

            // intermolecular coupling
            else
            {
                // calculate the distance between dipoles
                // they are located 0.67 A from the oxygen along the OH bond

                // tdm position on chromophore n
                mox[0]  = x[ m*natom_mol ][0];
                mox[1]  = x[ m*natom_mol ][1];
                mox[2]  = x[ m*natom_mol ][2];
                if ( chromm % 2 == 0 )       //HW1
                {
                    mhx[0]  = x[ m*natom_mol + 1 ][0];
                    mhx[1]  = x[ m*natom_mol + 1 ][1];
                    mhx[2]  = x[ m*natom_mol + 1 ][2];
                }
                else if ( chromm % 2 == 1 )  //HW2
                {
                    mhx[0]  = x[ m*natom_mol + 2 ][0];
                    mhx[1]  = x[ m*natom_mol + 2 ][1];
                    mhx[2]  = x[ m*natom_mol + 2 ][2];
                }

                // The OH unit vector
                moh[0] = minImage( mhx[0] - mox[0], boxl );
                moh[1] = minImage( mhx[1] - mox[1], boxl );
                moh[2] = minImage( mhx[2] - mox[2], boxl );
                r      = mag3(moh);
                moh[0] /= r;
                moh[1] /= r;
                moh[2] /= r;

                // The location of the TDM and the dipole derivative
                mmu[0] = minImage( mox[0] + 0.067 * moh[0], boxl );
                mmu[1] = minImage( mox[1] + 0.067 * moh[1], boxl );
                mmu[2] = minImage( mox[2] + 0.067 * moh[2], boxl );

                // the distance between TDM on N and on M and convert to unit vector
                dr[0] = minImage( nmu[0] - mmu[0], boxl );
                dr[1] = minImage( nmu[1] - mmu[1], boxl );
                dr[2] = minImage( nmu[2] - mmu[2], boxl );
                r     = mag3( dr );
                dr[0] /= r;
                dr[1] /= r;
                dr[2] /= r;
                r     *= bohr_nm; // convert to bohr

                // The coupling in the transition dipole approximation in wavenumber
                // Note the conversion to wavenumber
                kappa[chromn*nchrom + chromm]   = ( dot3( noh, moh ) - 3.0 * dot3( noh, dr ) * 
                                                    dot3( moh, dr ) ) / ( r*r*r ) * 
                                                    xn*xm*nmuprime*mmuprime*cm_hartree;
            }// end intramolecular coupling
        }// end loop over chromm
    }// end loop over reference
}


/**********************************************************
   
        Calculate the Spectral Density

 **********************************************************/
__global__
void get_spectral_density( float *w, float *MUX, float *MUY, float *MUZ, float *omega, float *Sw, 
                           int nomega, int nchrom, float t1 ){

    int istart, istride, i, chromn;
    float wi, dw, MU2, gamma;
    
    // split up each desired frequency to separate thread on GPU
    istart  =   blockIdx.x * blockDim.x + threadIdx.x;
    istride =   blockDim.x * gridDim.x;

    // the linewidth parameter
    gamma = HBAR/(t1 * 2.0);

    // Loop over the chromophores belonging to the current thread and fill in kappa for that row
    for ( i = istart; i < nomega; i += istride )
    {
        // get current frequency
        wi = omega[i];
        
        // Loop over all chromophores calculatint the spectral intensity at the current frequency
        for ( chromn = 0; chromn < nchrom; chromn ++ ){
            // calculate the TDM squared and get the mode energy
            MU2     = MUX[chromn]*MUX[chromn] + MUY[chromn]*MUY[chromn] + MUZ[chromn]*MUZ[chromn];
            dw      = wi - w[chromn];

            // add a lorentzian lineshape to the spectral density
            Sw[i] += MU2 * gamma / ( dw*dw + gamma*gamma )/PI;
        }
        //printf("Sw[%d]=%f\n", i, Sw[i]);
    }
}

/**********************************************************
   
        HELPER FUNCTIONS FOR GPU CALCULATIONS
            CALLABLE FROM CPU AND GPU

 **********************************************************/

// The minimage image of a scalar
float minImage( float dx, float boxl )
{
    return dx - boxl*round(dx/boxl);
}

// The magnitude of a 3 dimensional vector
float mag3( float dx[3] )
{
    return sqrt( dot3( dx, dx ) );
}

// The dot product of a 3 dimensional vector
float dot3( float x[3], float y[3] )
{
    return  x[0]*y[0] + x[1]*y[1] + x[2]*y[2];
}

// cast the matrix from float to complex -- this may not be the best way to do this, but it is quick to implement
__global__
void cast_to_complex_GPU ( float *s_d, magmaFloatComplex *c_d, int n )
{
    int istart, istride, i;
    
    // split up each desired frequency to separate thread on GPU
    istart  =   blockIdx.x * blockDim.x + threadIdx.x;
    istride =   blockDim.x * gridDim.x;

    // convert from float to complex
    for ( i = istart; i < n; i += istride )
    {
        c_d[i] = MAGMA_C_MAKE( s_d[i], 0.0 ); 
    }
}
