/*This is my first attempt to port my python ir program to cuda. 
 * It currently suffers from **very** slow excecution in python. 
 * I'm going to try to port it to cuda c */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <xdrfile/xdrfile.h>
#include <xdrfile/xdrfile_xtc.h>
#include "calcIR.h"
#include <complex.h>
#include <time.h>

#include "magma_v2.h"
#include <cufft.h>

int main(int argc, char *argv[])
{

    // ***              Variable Declaration            *** //
    // **************************************************** //

    printf("\n>>> Setting default parameters\n");
    // Default values for user input
    char          gmxf[MAX_STR_LEN]; 
    strncpy( gmxf, "n216/traj_comp.xtc", MAX_STR_LEN );                   // trajectory file
    char          outf[MAX_STR_LEN]; 
    strncpy( outf, " ", MAX_STR_LEN );                                    // name for output files
    char          model[MAX_STR_LEN];
    strncpy( model, "tip4p", MAX_STR_LEN );
    int           imodel        = 0;
    int           ispecd        = 0;
    int           ifintmeth     = 0;
    user_real_t   dt            = 0.010;                                  // dt between frames in xtc file (in ps)
    int           ntcfpoints    = 150 ;                                   // the number of tcf points for each spectrum
    int           nsamples      = 1   ;                                   // number of samples to average for the total spectrum
    int           sampleEvery   = 10  ;                                   // sample a new configuration every sampleEvery ps. Note ntcfpoints*dt must be less than sampleEvery.
    user_real_t   beginTime     = 0   ;                                   // the beginning time in ps to allow for equilibration

    user_real_t   t1            = 0.260;                                  // relaxation time ( in ps )
    user_real_t   avef          = 3415.2;                                 // the approximate average stretch frequency to get rid of high frequency oscillations in the time correlation function
    int           omegaStart    = 2000;                                   // starting frequency for spectral density
    int           omegaStop     = 5000;                                   // ending frequency for spectral density
    int           omegaStep     = 5;                                      // resolution for spectral density

    int           natom_mol     = 4;                                      // Atoms per water molecule  :: MODEL DEPENDENT
    int           nchrom_mol    = 2;                                      // Chromophores per molecule :: TWO for stretch -- ONE for bend
    int           nzeros        = 25600;                                  // zeros for padding fft

    user_real_t   max_int_steps = 2.0;                                    // number of Adams integration steps between each dt

 
    // get user input parameters
    ir_init( argv, gmxf, outf, model, &ifintmeth, &dt, &ntcfpoints, &nsamples, &sampleEvery, &t1, 
             &avef, &omegaStart, &omegaStop, &omegaStep, &natom_mol, &nchrom_mol, &nzeros, &beginTime,
             &ispecd, &max_int_steps);

    // Some useful variables and constants
    int                 natoms, nmol, frame, nchrom;
    magma_int_t         nchrom2;
    const int           ntcfpointsR     = (nzeros + ntcfpoints - 1)*2;                  // number of points for the real fourier transform
    const int           nomega          = ( omegaStop - omegaStart ) / omegaStep + 1;   // number of frequencies for the spectral density
    int                 currentSample   = 0;                                            // current sample

    // set model to integer to pass to gpu kernel to test in if statement for remaking OM bond lengths
    if ( strcmp( model, "tip4p2005" ) == 0 || strcmp( model, "e3b3" ) == 0 ) imodel = 1;
    else imodel = 0;

    // Trajectory stuff for the CPU
    rvec                *x;                                                             // Position vector
    matrix              box;                                                            // Box vectors
    float               boxl, gmxtime, prec;                                            // Box lengths, time at current frame, precision of xtf file
    int                 step, xdrinfo;                                                  // The current step number

    // Some variables for the GPU
    rvec                *x_d;                                                           // positions
    user_real_t         *mux_d, *muy_d, *muz_d;                                         // transition dipole moments
    user_complex_t      *cmux0_d, *cmuy0_d, *cmuz0_d;                                   // complex version of the transition dipole moment at t=0 
    user_complex_t      *cmux_d, *cmuy_d, *cmuz_d;                                      // complex versions of the transition dipole moment
    user_complex_t      *tmpmu_d;                                                       // to sum all polarizations
    user_real_t         *MUX_d, *MUY_d, *MUZ_d;                                         // transition dipole moments in the eigen basis
    user_real_t         *eproj_d;                                                       // the electric field projected along the oh bonds
    user_real_t         *kappa_d;                                                       // the hamiltonian on the GPU
    const int           blockSize = 128;                                                // The number of threads to launch per block


    // Variables for F matrix integration
    user_complex_t      *k1_d, *k2_d, *k3_d, *k4_d;                                     // Adams integration variables
    int                 order_counter = 0 ;                                             // To keep track of the current order of the Adams method
    user_real_t         arg;                                                            // argument of exponential

    // magma variables for ssyevr
    user_real_t         aux_work[1];                                                    // To get optimal size of lwork
    magma_int_t         aux_iwork[1], info;                                             // To get optimal liwork, and return info
    magma_int_t         lwork, liwork;                                         // Leading dim of kappa, sizes of work arrays
    magma_int_t         *iwork;                                                         // Work array
    user_real_t         *work;                                                          // Work array
    user_real_t         *w   ;                                                          // Eigenvalues
    user_real_t         *wA  ;                                                          // Work array

    // magma variables for gemv
    magma_queue_t       queue;

    // variables for spectrum calculations
    user_real_t         *w_d;                                                           // Eigenvalues on the GPU
    user_real_t         *omega, *omega_d;                                               // Frequencies on CPU and GPU
    user_real_t         *Sw, *Sw_d;                                                     // Spectral density on CPU and GPU
    user_real_t         *tmpSw;                                                         // Temporary spectral density

    // variables for TCF
    user_complex_t      *F, *F_d;                                                       // F matrix on CPU and GPU
    user_complex_t      *prop, *prop_d;                                                 // Propigator matrix on CPU and GPU
    user_complex_t      *ctmpmat_d;                                                     // temporary complex matrix for matrix multiplications on gpu
    user_complex_t      *ckappa_d;                                                      // A complex version of kappa // TODO: CAN WE JUST CAST AS TYPE INSTEAD OF HAVING VARIABLES FOR THIS?
    user_complex_t      tcfx, tcfy, tcfz;                                               // Time correlation function, polarized
    user_complex_t      dcy, tcftmp;                                                    // Decay constant and a temporary variable for the tcf
    user_complex_t      *pdtcf, *pdtcf_d;                                               // padded time correlation functions
    user_complex_t      *tcf, *tcf_d;                                                   // Time correlation function
    user_complex_t      *tmptcf;                                                        // A temporary function for time correlation function
    user_real_t         *Ftcf, *Ftcf_d;                                                 // Fourier transformed time correlation function
    user_real_t         *time2;                                                         // Time array for tcf

    // For fft on gpu
    cufftHandle         plan;

    // for timing
    time_t              start=time(NULL), end;

    // **************************************************** //
    // ***         End  Variable Declaration            *** //


    



    // ***          Begin main routine                  *** //
    // **************************************************** //

    // Open trajectory file and get info about the systeem

    XDRFILE *trj = xdrfile_open( gmxf, "r" ); 
    if ( trj == NULL )
    {
        printf("WARNING: The file %s could not be opened. Is the name correct?\n", gmxf);
        exit(EXIT_FAILURE);
    }
    printf(">>> Will read the trajectory from: %s.\n",gmxf);


    read_xtc_natoms( (char *)gmxf, &natoms);
    nmol         = natoms / natom_mol;
    nchrom       = nmol * nchrom_mol;
    nchrom2      = (magma_int_t) nchrom*nchrom;

    printf(">>> Found %d atoms and %d molecules.\n",natoms, nmol);
    printf(">>> Found %d chromophores.\n",nchrom);


    // ***              MEMORY ALLOCATION               *** //
    // **************************************************** //

    // determine the number of blocks to launch on the gpu 
    // each thread takes care of one chromophore for building the electric field and Hamiltonian
    const int numBlocks = (nchrom+blockSize-1)/blockSize;
    
    // Initialize magma math library and initialize queue
    magma_init();
    magma_queue_create( 0, &queue ); 

    // CPU arrays
    x       = (rvec*)            malloc( natoms       * sizeof(x[0] ));
    time2   = (user_real_t *)    malloc( ntcfpoints   * sizeof(user_real_t));
    Ftcf    = (user_real_t *)    calloc( ntcfpointsR  , sizeof(user_real_t));
    tmptcf  = (user_complex_t *) malloc( ntcfpoints   * sizeof(user_complex_t));
    tcf     = (user_complex_t *) calloc( ntcfpoints   , sizeof(user_complex_t));
    F       = (user_complex_t *) calloc( nchrom2      , sizeof(user_complex_t));

    // GPU arrays
    cudaMalloc( &x_d      , natoms       *sizeof(x[0]));
    cudaMalloc( &Ftcf_d   , ntcfpointsR  *sizeof(user_real_t));
    cudaMalloc( &mux_d    , nchrom       *sizeof(user_real_t));
    cudaMalloc( &muy_d    , nchrom       *sizeof(user_real_t));
    cudaMalloc( &muz_d    , nchrom       *sizeof(user_real_t));
    cudaMalloc( &eproj_d  , nchrom       *sizeof(user_real_t));
    cudaMalloc( &kappa_d  , nchrom2      *sizeof(user_real_t));
    cudaMalloc( &cmux_d   , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &cmuy_d   , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &cmuz_d   , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &cmux0_d  , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &cmuy0_d  , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &cmuz0_d  , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &tmpmu_d  , nchrom       *sizeof(user_complex_t));
    cudaMalloc( &ckappa_d , nchrom2      *sizeof(user_complex_t));
    cudaMalloc( &F_d      , nchrom2      *sizeof(user_complex_t));
    cudaMalloc( &ctmpmat_d, nchrom2      *sizeof(user_complex_t));
    cudaMalloc( &tcf_d    , ntcfpoints   *sizeof(user_complex_t));


    // memory for spectral density calculation, if requested
    if ( ispecd == 0 )
    {
        // CPU arrays
        omega   = (user_real_t *)    malloc( nomega       * sizeof(user_real_t));
        Sw      = (user_real_t *)    calloc( nomega       , sizeof(user_real_t));
        tmpSw   = (user_real_t *)    malloc( nomega       * sizeof(user_real_t));

        // GPU arrays
        cudaMalloc( &MUX_d   , nchrom       *sizeof(user_real_t));
        cudaMalloc( &MUY_d   , nchrom       *sizeof(user_real_t));
        cudaMalloc( &MUZ_d   , nchrom       *sizeof(user_real_t));
        cudaMalloc( &omega_d , nomega       *sizeof(user_real_t));
        cudaMalloc( &Sw_d    , nomega       *sizeof(user_real_t));
        cudaMalloc( &w_d     , nchrom       *sizeof(user_real_t));
    }
 

    // memory for integration of F depending on which method is used
    if ( ifintmeth == 0 ) // exact
    {
        prop    = (user_complex_t *) calloc( nchrom2      , sizeof(user_complex_t));
        cudaMalloc( &prop_d  , nchrom2      *sizeof(user_complex_t));
    }
    else if ( ifintmeth == 1 ) // adams integration
    {
        cudaMalloc( &k1_d    , nchrom2      *sizeof(user_complex_t));
        cudaMalloc( &k2_d    , nchrom2      *sizeof(user_complex_t));
        cudaMalloc( &k3_d    , nchrom2      *sizeof(user_complex_t));
        cudaMalloc( &k4_d    , nchrom2      *sizeof(user_complex_t));
    }

    // ***          END MEMORY ALLOCATION               *** //
    // **************************************************** //
    




    
    // **************************************************** //
    // ***          OUTER LOOP OVER SAMPLES             *** //

    printf("\n>>> Now calculate the absorption spectrum\n");
    printf("----------------------------------------------------------\n");


    while( currentSample < nsamples )
    {
        // search trajectory for current sample starting point
        xdrinfo = read_xtc( trj, natoms, &step, &gmxtime, box, x, &prec );

        if ( xdrinfo != 0 )
        {
            printf("WARNING:: read_xtc returned error %d.\nIs the trajectory long enough?\n", xdrinfo);
            exit(0);
        }

        if ( currentSample * sampleEvery + (int) beginTime == (int) gmxtime )
        {
            printf("\n    Now processing sample %d/%d starting at %.2f ps\n", currentSample + 1, nsamples, gmxtime );


        // **************************************************** //
        // ***         MAIN LOOP OVER TRAJECTORY            *** //
        for ( frame = 0; frame < ntcfpoints; frame++ )
        {


            // ---------------------------------------------------- //
            // ***          Get Info About The System           *** //


            // read the current frame from the trajectory file and copy to device memory
            // note it was read in the outer loop if we are at frame 0
            // also assume a square box, but this will need to be changed if it is not the case
            if ( frame != 0 ){
                read_xtc( trj, natoms, &step, &gmxtime, box, x, &prec );
            }
            cudaMemcpy( x_d, x, natoms*sizeof(x[0]), cudaMemcpyHostToDevice );
            boxl = box[0][0];

            // launch kernel to calculate the electric field projection along OH bonds and build the exciton hamiltonian
            get_eproj_GPU <<<numBlocks,blockSize>>> ( x_d, boxl, natoms, natom_mol, nchrom, nchrom_mol, nmol, imodel, eproj_d );

            get_kappa_GPU <<<numBlocks,blockSize>>> ( x_d, boxl, natoms, natom_mol, nchrom, nchrom_mol, nmol, eproj_d, 
                                                      kappa_d, mux_d, muy_d, muz_d, avef );


            // ***          Done getting System Info            *** //
            // ---------------------------------------------------- //




            // ---------------------------------------------------- //
            // ***          Diagonalize the Hamiltonian         *** //


            // Note that kappa only needs to be diagonalized if the exact integration method is requested or the spectral density
            if ( ifintmeth == 0 || ispecd == 0 )
            {


                // if the first time, query for optimal workspace dimensions
                if ( frame == 0 && currentSample == 0 )
                {
#ifdef USE_DOUBLES
                    magma_dsyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, NULL, (magma_int_t) nchrom, 
                                      NULL, NULL, (magma_int_t) nchrom, aux_work, -1, aux_iwork, -1, &info );
#else
                    magma_ssyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, NULL, (magma_int_t) nchrom, 
                                      NULL, NULL, (magma_int_t) nchrom, aux_work, -1, aux_iwork, -1, &info );
#endif
                    lwork   = (magma_int_t) aux_work[0];
                    liwork  = aux_iwork[0];

                    // allocate work arrays, eigenvalues and other stuff
                    w       = (user_real_t *)    malloc( nchrom       * sizeof(user_real_t));
                    magma_imalloc_cpu   ( &iwork, liwork );
#ifdef USE_DOUBLES
                    magma_dmalloc_pinned( &wA , nchrom2 );
                    magma_dmalloc_pinned( &work , lwork  );
#else
                    magma_smalloc_pinned( &wA , nchrom2 );
                    magma_smalloc_pinned( &work , lwork  );
#endif
                }

#ifdef USE_DOUBLES
                magma_dsyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, kappa_d, (magma_int_t) nchrom,
                                  w, wA, (magma_int_t) nchrom, work, lwork, iwork, liwork, &info );
#else
                magma_ssyevd_gpu( MagmaVec, MagmaUpper, (magma_int_t) nchrom, kappa_d, (magma_int_t) nchrom,
                                  w, wA, (magma_int_t) nchrom, work, lwork, iwork, liwork, &info );
#endif
            }

            // ***          Done with the Diagonalization       *** //
            // ---------------------------------------------------- //




            // ---------------------------------------------------- //
            // ***              The Spectral Density            *** //

            if ( frame == 0 && ispecd == 0)
            {

                // project the transition dipole moments onto the eigenbasis
                // MU_d = kappa_d**T x mu_d 
#ifdef USE_DOUBLES
                magma_dgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom , mux_d, 1, 0.0, MUX_d, 1, queue);
                magma_dgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom, muy_d, 1, 0.0, MUY_d, 1, queue);
                magma_dgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom, muz_d, 1, 0.0, MUZ_d, 1, queue);
#else
                magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom , mux_d, 1, 0.0, MUX_d, 1, queue);
                magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom, muy_d, 1, 0.0, MUY_d, 1, queue);
                magma_sgemv( MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                             1.0, kappa_d, (magma_int_t) nchrom, muz_d, 1, 0.0, MUZ_d, 1, queue);
#endif

                // Define the spectral range of interest and initialize spectral arrays
                for (int i = 0; i < nomega; i++)
                {
                    omega[i] = (user_real_t) (omegaStart + omegaStep*i); 
                    tmpSw[i] = 0.0;
                }

                // Copy relevant variables to device memory
                cudaMemcpy( omega_d, omega, nomega*sizeof(user_real_t), cudaMemcpyHostToDevice );
                cudaMemcpy( w_d    , w    , nchrom*sizeof(user_real_t), cudaMemcpyHostToDevice );
                cudaMemcpy( Sw_d   , tmpSw, nomega*sizeof(user_real_t), cudaMemcpyHostToDevice );

                // calculate the spectral density on the GPU and copy back to the CPU
                get_spectral_density <<<numBlocks,blockSize>>> ( w_d, MUX_d, MUY_d, MUZ_d, omega_d, Sw_d, nomega, nchrom, t1, avef );
                cudaMemcpy( tmpSw, Sw_d, nomega*sizeof(user_real_t), cudaMemcpyDeviceToHost );

                // Copy temporary to persistant to get average spectral density over samples
                for (int i = 0; i < nomega; i++ )
                {
                    Sw[i] += tmpSw[i];
                }
            }

            // ***           Done the Spectral Density          *** //
            // ---------------------------------------------------- //




            // ---------------------------------------------------- //
            // ***           Time Correlation Function          *** //

            // cast variables to complex to calculate time correlation function (which is complex)
            cast_to_complex_GPU <<<numBlocks,blockSize>>> ( kappa_d, ckappa_d, nchrom2);
            cast_to_complex_GPU <<<numBlocks,blockSize>>> ( mux_d  , cmux_d  , nchrom );
            cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muy_d  , cmuy_d  , nchrom );
            cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muz_d  , cmuz_d  , nchrom );


            // ---------------------------------------------------- //
            // ***           Calculate the F matrix             *** //

            if ( frame == 0 )
            {
                // initialize the F matrix at t=0 to the unit matrix
                // TODO: Initialize on GPU memory and get rid of host F matrix
                for ( int i = 0; i < nchrom; i ++ )
                {
                    for ( int j = 0; j < nchrom; j ++ )
                    {
                        F[ i*nchrom + j] = MAGMA_ZERO;
                    }
                    F[ i*nchrom + i] = MAGMA_ONE;
                }
                // copy the F matrix to device memory -- after initialization, won't need back in host memory
                cudaMemcpy( F_d, F, nchrom2*sizeof(user_complex_t), cudaMemcpyHostToDevice );

                // set the transition dipole moment at t=0
                cast_to_complex_GPU <<<numBlocks,blockSize>>> ( mux_d  , cmux0_d  , nchrom );
                cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muy_d  , cmuy0_d  , nchrom );
                cast_to_complex_GPU <<<numBlocks,blockSize>>> ( muz_d  , cmuz0_d  , nchrom );
            }
            else
            {
                if ( ifintmeth == 0 )   // Integrate with exact diagonalization
                {
                    // build the propigator
                    // TODO, build on GPU and get rid of CPU array
                    for ( int i = 0; i < nchrom; i++ )
                    {
                        // zero matrix
                        for ( int j = 0; j < nchrom; j ++ )
                        {
                            prop[ i*nchrom + j] = MAGMA_ZERO;
                        }
                        // P = exp(iwt/hbar)
                        arg   = w[i] * dt / HBAR;
                        prop[ i*nchrom + i ] = MAGMA_MAKE( cos(arg), sin(arg) );
                    }

                    // copy the propigator to the gpu and convert to the local basis
                    cudaMemcpy( prop_d, prop, nchrom2*sizeof(user_complex_t), cudaMemcpyHostToDevice );

#ifdef USE_DOUBLES
                    // ctmpmat_d = ckappa_d * prop_d
                    magma_zgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, ckappa_d, (magma_int_t) nchrom, prop_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, ctmpmat_d, (magma_int_t) nchrom, queue );

                    // prop_d = ctmpmat_d * ckappa_d **T 
                    magma_zgemm( MagmaNoTrans, MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, ctmpmat_d, (magma_int_t) nchrom, ckappa_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, prop_d, (magma_int_t) nchrom, queue );

                    // ctmpmat_d = prop_d * F
                    magma_zgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, prop_d, (magma_int_t) nchrom, F_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, ctmpmat_d, (magma_int_t) nchrom, queue );

                    // copy the F matrix back from the temporary variable to F_d
                    magma_zcopy( (magma_int_t) nchrom2, ctmpmat_d , 1, F_d, 1, queue );
#else
                    // ctmpmat_d = ckappa_d * prop_d
                    magma_cgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, ckappa_d, (magma_int_t) nchrom, prop_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, ctmpmat_d, (magma_int_t) nchrom, queue );

                    // prop_d = ctmpmat_d * ckappa_d **T 
                    magma_cgemm( MagmaNoTrans, MagmaTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, ctmpmat_d, (magma_int_t) nchrom, ckappa_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, prop_d, (magma_int_t) nchrom, queue );

                    // ctmpmat_d = prop_d * F
                    magma_cgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                 (magma_int_t) nchrom, MAGMA_ONE, prop_d, (magma_int_t) nchrom, F_d, 
                                 (magma_int_t) nchrom, MAGMA_ZERO, ctmpmat_d, (magma_int_t) nchrom, queue );

                    // copy the F matrix back from the temporary variable to F_d
                    magma_ccopy( (magma_int_t) nchrom2, ctmpmat_d , 1, F_d, 1, queue );
#endif
                }
                else if ( ifintmeth == 1 ) // Integrate F with 4th order Adams-Bashfort
                {                          // Note: The kappa matrix is assumed to be time independent over this integration cycle of max_int_steps
                    // reset current order if at the begining of a sample
                    if ( frame == 1 ) order_counter = 1;

                    for ( int i=0; i<(int) max_int_steps; i++ )// take multiple steps
                    {
#ifdef USE_DOUBLES
                        // find current dF/dt = iF(t+i)k(t)
                        magma_zgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                    (magma_int_t) nchrom, MAGMA_MAKE(0.0,1.0), F_d, nchrom, ckappa_d, nchrom,
                                     MAGMA_ZERO, ctmpmat_d, nchrom, queue );

                        // For the first step use Euler since previous values are not available
                        if ( order_counter == 1 )
                        //if ( frame == 0 && i == 0 )
                        {
                            // save current value for later
                            magma_zcopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k1_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 2;
                        }
                        // use ADAMS bensforth two-step method for step 2
                        else if ( order_counter == 2 )
                        //else if ( frame == 0 && i == 1 )
                        {
                            // save current values for later
                            magma_zcopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k2_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 3.0/2.0*dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-1.0/2.0*dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 3;
                        }
                        // use ADAMS bensforth three-step method
                        //else if ( frame == 0 && i == 2 )
                        else if ( order_counter == 3 )
                        {
                            // save current values for later
                            magma_zcopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k3_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(23.0/12.0*dt/HBAR/max_int_steps,0), k3_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-4.0/3.0 *dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 5.0/12.0*dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 4;
                        }
                        // use ADAMS bensforth four-step method
                        else
                        {
                            // save current values for later
                            magma_zcopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k4_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 55.0/24.0 *dt/HBAR/max_int_steps,0), k4_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-59.0/24.0 *dt/HBAR/max_int_steps,0), k3_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 37.0/24.0 *dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_zaxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-3.0/8.0   *dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            // shuffle definitions for next iteration //
                            magma_zcopy( (magma_int_t) nchrom2, k2_d, 1, k1_d, 1, queue );
                            magma_zcopy( (magma_int_t) nchrom2, k3_d, 1, k2_d, 1, queue );
                            magma_zcopy( (magma_int_t) nchrom2, k4_d, 1, k3_d, 1, queue );
                        }

#else
                        // find current dF/dt = iF(t+i)k(t)
                        magma_cgemm( MagmaNoTrans, MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, 
                                    (magma_int_t) nchrom, MAGMA_MAKE(0.0,1.0), F_d, nchrom, ckappa_d, nchrom,
                                     MAGMA_ZERO, ctmpmat_d, nchrom, queue );

                        // For the first step use Euler since previous values are not available
                        if ( order_counter == 1 )
                        //if ( frame == 0 && i == 0 )
                        {
                            // save current value for later
                            magma_ccopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k1_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 2;
                        }
                        // use ADAMS bensforth two-step method for step 2
                        else if ( order_counter == 2 )
                        //else if ( frame == 0 && i == 1 )
                        {
                            // save current values for later
                            magma_ccopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k2_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 3.0/2.0*dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-1.0/2.0*dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 3;
                        }
                        // use ADAMS bensforth three-step method
                        //else if ( frame == 0 && i == 2 )
                        else if ( order_counter == 3 )
                        {
                            // save current values for later
                            magma_ccopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k3_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(23.0/12.0*dt/HBAR/max_int_steps,0), k3_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-4.0/3.0 *dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 5.0/12.0*dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            order_counter = 4;
                        }
                        // use ADAMS bensforth four-step method
                        else
                        {
                            // save current values for later
                            magma_ccopy( (magma_int_t) nchrom2, ctmpmat_d , 1, k4_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 55.0/24.0 *dt/HBAR/max_int_steps,0), k4_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-59.0/24.0 *dt/HBAR/max_int_steps,0), k3_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE( 37.0/24.0 *dt/HBAR/max_int_steps,0), k2_d, 1, F_d, 1, queue );
                            magma_caxpy( (magma_int_t) nchrom2, MAGMA_MAKE(-3.0/8.0   *dt/HBAR/max_int_steps,0), k1_d, 1, F_d, 1, queue );
                            // shuffle definitions for next iteration //
                            magma_ccopy( (magma_int_t) nchrom2, k2_d, 1, k1_d, 1, queue );
                            magma_ccopy( (magma_int_t) nchrom2, k3_d, 1, k2_d, 1, queue );
                            magma_ccopy( (magma_int_t) nchrom2, k4_d, 1, k3_d, 1, queue );
                        }
#endif
                    }
                }
            }
            // ***           Done updating the F matrix         *** //


            // calculate mFm for x y and z components
            // tcfx = cmux0_d**T * F_d *cmux_d
#ifdef USE_DOUBLES
            // x
            magma_zgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_ONE, F_d, (magma_int_t) nchrom,
                         cmux0_d, 1, MAGMA_ZERO, tmpmu_d, 1, queue);
            tcfx = magma_zdotu( (magma_int_t) nchrom, cmux_d, 1, tmpmu_d, 1, queue );

            // y
            magma_zgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_ONE, F_d, (magma_int_t) nchrom,
                         cmuy0_d, 1, MAGMA_ZERO, tmpmu_d, 1, queue);
            tcfy = magma_zdotu( (magma_int_t) nchrom, cmuy_d, 1, tmpmu_d, 1, queue );

            // z
            magma_zgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_ONE, F_d, (magma_int_t) nchrom,
                         cmuz0_d, 1, MAGMA_ZERO, tmpmu_d, 1, queue);
            tcfz = magma_zdotu( (magma_int_t) nchrom, cmuz_d, 1, tmpmu_d, 1, queue );
#else
            // x
            magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, (magma_int_t) nchrom,
                         cmux0_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
            tcfx = magma_cdotu( (magma_int_t) nchrom, cmux_d, 1, tmpmu_d, 1, queue );

            // y
            magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, (magma_int_t) nchrom,
                         cmuy0_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
            tcfy = magma_cdotu( (magma_int_t) nchrom, cmuy_d, 1, tmpmu_d, 1, queue );

            // z
            magma_cgemv( MagmaNoTrans, (magma_int_t) nchrom, (magma_int_t) nchrom, MAGMA_C_ONE, F_d, (magma_int_t) nchrom,
                         cmuz0_d, 1, MAGMA_C_ZERO, tmpmu_d, 1, queue);
            tcfz = magma_cdotu( (magma_int_t) nchrom, cmuz_d, 1, tmpmu_d, 1, queue );
#endif

            // save the variables to print later and multiply by the decay
            time2[frame]          = dt * frame;
            tcftmp                = MAGMA_ADD( tcfx  , tcfy );
            tcftmp                = MAGMA_ADD( tcftmp, tcfz );
            dcy                   = MAGMA_MAKE(exp( -1.0 * frame * dt / ( 2.0 * t1 )), 0.0);
            tmptcf[frame]         = MAGMA_MUL( tcftmp, dcy );

 
            // ***        Done with Time Correlation            *** //
            // ---------------------------------------------------- //

            // update progress bar if big enough, otherwise it really isn't necessary
            if ( nchrom > 400 )
            {
                printProgress( frame, ntcfpoints-1 );
            }

        }

        // copy time correlation function to persistant variable to calculate average spectrum
        for ( int i = 0; i < ntcfpoints; i ++ )
        {
            tcf[i]  = MAGMA_ADD( tcf[i] , tmptcf[i]);
        }

        // done with current sample, move to next
        currentSample +=1;
        }
    } // end outer loop


    printf("\n\n----------------------------------------------------------\n");
    printf("Finishing up...\n");

    // close xdr file
    xdrfile_close(trj);


    // pad the time correlation function with zeros, copy to device memory and perform fft
    // fourier transform the time correlation function on the GPU
    pdtcf = (user_complex_t *) calloc( ntcfpoints+nzeros, sizeof(user_complex_t));
    for ( int i = 0; i < ntcfpoints; i++ )
    {
        pdtcf[i] = MAGMA_DIV(tcf[i], MAGMA_MAKE( nsamples, 0.0 ));
    }
    for ( int i = 0; i < nzeros; i++ )
    {
        pdtcf[i+ntcfpoints] = MAGMA_ZERO;
    }

    cudaMalloc( &pdtcf_d  , (ntcfpoints+nzeros)*sizeof(user_complex_t));
    cudaMemcpy( pdtcf_d, pdtcf, (ntcfpoints+nzeros)*sizeof(user_complex_t), cudaMemcpyHostToDevice );

#ifdef USE_DOUBLES
    cufftPlan1d  ( &plan, ntcfpoints+nzeros, CUFFT_Z2D, 1);
    cufftExecZ2D ( plan, pdtcf_d, Ftcf_d );
#else
    cufftPlan1d  ( &plan, ntcfpoints+nzeros, CUFFT_C2R, 1);
    cufftExecC2R ( plan, pdtcf_d, Ftcf_d );
#endif
    cudaMemcpy   ( Ftcf, Ftcf_d, ntcfpointsR*sizeof(user_real_t), cudaMemcpyDeviceToHost );
    cufftDestroy(plan);


    // normalize spectra by number of samples
    for ( int i = 0; i < ntcfpointsR; i++ )
    {
        Ftcf[i] = Ftcf[i] ;/// (user_real_t) nsamples; 
    }
    if ( ispecd == 0 )
    {
        for ( int i = 0; i < nomega; i++)
        {
            Sw[i]   = Sw[i] / (user_real_t) nsamples;
        }
    }

    // set base name for output files
    char * fname;
    fname = (char *) malloc( strlen(outf) + 9 );

    // write time correlation function
    FILE *rtcf = fopen(strcat(strcpy(fname,outf),"rtcf.dat"), "w");
    FILE *itcf = fopen(strcat(strcpy(fname,outf),"itcf.dat"), "w");
    for ( int i = 0; i < ntcfpoints; i++ )
    {
        fprintf( rtcf, "%g %g \n", time2[i], MAGMA_REAL( tcf[i] ) );
        fprintf( itcf, "%g %g \n", time2[i], MAGMA_IMAG( tcf[i] ) );
    }
    fclose( rtcf );
    fclose( itcf );

    // write the spectral density to file
    if ( ispecd == 0 )
    {
        FILE *spec_density = fopen(strcat(strcpy(fname,outf),"spdn.dat"), "w");
        for ( int i = 0; i < nomega; i++)
        {
            fprintf(spec_density, "%g %g\n", omega[i], Sw[i]);
        }
        fclose(spec_density);
    }

    // Write the absorption lineshape... Since the C2R transform is inverse by default, the frequencies have to be negated
    // note if you need to compare with YICUN's code, divide Ftcf by 2
    FILE *spec_lineshape = fopen(strcat(strcpy(fname,outf),"spec.dat"),"w");
    user_real_t factor   = 2*PI*HBAR/(dt*(ntcfpoints+nzeros));          // conversion factor to give energy and correct intensity from FFT
    for ( int i = (ntcfpoints+nzeros)/2; i < ntcfpoints+nzeros; i++ )   // "negative" FFT frequencies
    {
        if ( -1*(i-ntcfpoints-nzeros)*factor + avef <= (user_real_t) omegaStop  )
        {
            fprintf(spec_lineshape, "%g %g\n", -1*(i-ntcfpoints-nzeros)*factor + avef, Ftcf[i]/(factor*(ntcfpoints+nzeros)));// TO COMPARE WITH YICUN
        }
    }
    for ( int i = 0; i < ntcfpoints+nzeros / 2 ; i++)                   // "positive" FFT frequencies
    {
        if ( -1*i*factor + avef >= (user_real_t) omegaStart)
        {
            fprintf(spec_lineshape, "%g %g\n", -1*i*factor + avef, Ftcf[i]/(factor*(ntcfpoints+nzeros)));// TO COMPARE WITH YICUN
        }
    }
    fclose(spec_lineshape);

    // free memory on the CPU and GPU and finalize magma library
    magma_queue_destroy( queue );

    free(x);
    free(time2);
    free(Ftcf);
    free(tcf);
    free(F);
    free(pdtcf);
        

    cudaFree(x_d);
    cudaFree(Ftcf_d);
    cudaFree(mux_d); 
    cudaFree(muy_d);
    cudaFree(muz_d);
    cudaFree(eproj_d);
    cudaFree(kappa_d);
    cudaFree(cmux_d); 
    cudaFree(cmuy_d);
    cudaFree(cmuz_d);
    cudaFree(cmux0_d); 
    cudaFree(cmuy0_d);
    cudaFree(cmuz0_d);
    cudaFree(tmpmu_d);
    cudaFree(ckappa_d); 
    cudaFree(F_d);
    cudaFree(ctmpmat_d);
    cudaFree(tcf_d);

    magma_free(pdtcf_d);


    // free memory used for diagonalization
    if ( ispecd == 0 || ifintmeth == 0 )
    {
        free(w);
        free(iwork);
        magma_free_pinned( work );
        magma_free_pinned( wA );
    }

    // free memory used in spectral density calculation
    if ( ispecd == 0 ) // only used if the spetral density is calculated
    {
        // CPU arrays
        free(omega);
        free(Sw);
        free(tmpSw);

        // GPU arrays
        cudaFree(MUX_d); 
        cudaFree(MUY_d);
        cudaFree(MUZ_d);
        cudaFree(omega_d);
        cudaFree(Sw_d);
        cudaFree(w_d);
    }
 
    // free memory for integration of F depending on which method is used
    if ( ifintmeth == 0 ) // only used for the exact integration method
    {
        free(prop);
        cudaFree(prop_d);
    }
    else if ( ifintmeth == 1 ) // only used for adams integration method
    {
        cudaFree(k1_d);
        cudaFree(k2_d);
        cudaFree(k3_d);
        cudaFree(k4_d);
    }



    // final call to finalize magma math library
    magma_finalize();

    end = time(NULL);
    printf("\n>>> Done with the calculation in %f seconds.\n", difftime(end,start));

    return 0;
}

/**********************************************************
   
   BUILD ELECTRIC FIELD PROJECTION ALONG OH BONDS
                    GPU FUNCTION

 **********************************************************/
__global__
void get_eproj_GPU( rvec *x, float boxl, int natoms, int natom_mol, int nchrom, int nchrom_mol, int nmol, int model, user_real_t  *eproj )
{
    
    int n, m, i, j, istart, istride;
    int chrom;
    user_real_t mox[DIM];                     // oxygen position on molecule m
    user_real_t mx[DIM];                      // atom position on molecule m
    user_real_t nhx[DIM];                     // hydrogen position on molecule n of the current chromophore
    user_real_t nox[DIM];                     // oxygen position on molecule n
    user_real_t nohx[DIM];                    // the unit vector pointing along the OH bond for the current chromophore
    user_real_t mom[DIM];                     // the OM vector on molecule m
    user_real_t dr[DIM];                      // the min image vector between two atoms
    user_real_t r;                            // the distance between two atoms 
    const float cutoff = 0.7831;         // the oh cutoff distance
    const float bohr_nm = 18.8973;       // convert from bohr to nanometer
    user_real_t efield[DIM];                  // the electric field vector

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

        // for testing with YICUN -- can change to ROH later...
        //nohx[0] /= 0.09572;
        //nohx[1] /= 0.09572;
        //nohx[2] /= 0.09572;
 
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

                // Move m site to TIP4P distance if model is E3B3 or TIP4P2005 -- this must be done to use the TIP4P map
                if ( i == 3 )
                {
                    if ( model != 0 ) 
                    {
                        // get the OM unit vector
                        mom[0] = minImage( mx[0] - mox[0], boxl);
                        mom[1] = minImage( mx[1] - mox[1], boxl);
                        mom[2] = minImage( mx[2] - mox[2], boxl);
                        r      = mag3(mom);

                        // TIP4P OM distance is 0.015 nm along the OM bond
                        mx[0] = mox[0] + 0.0150*mom[0]/r;
                        mx[1] = mox[1] + 0.0150*mom[1]/r;
                        mx[2] = mox[2] + 0.0150*mom[2]/r;
                    }
                }

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

    } // end loop over reference chromophores
}

/**********************************************************
   
   BUILD HAMILTONIAN AND RETURN TRANSITION DIPOLE VECTOR
    FOR EACH CHROMOPHORE ON THE GPU

 **********************************************************/
__global__
void get_kappa_GPU( rvec *x, float boxl, int natoms, int natom_mol, int nchrom, int nchrom_mol, int nmol, 
                    user_real_t *eproj, user_real_t *kappa, user_real_t *mux, user_real_t *muy, user_real_t *muz, user_real_t avef)
{
    
    int n, m, istart, istride;
    int chromn, chromm;
    user_real_t mox[DIM];                         // oxygen position on molecule m
    user_real_t mhx[DIM];                         // atom position on molecule m
    user_real_t nhx[DIM];                         // hydrogen position on molecule n of the current chromophore
    user_real_t nox[DIM];                         // oxygen position on molecule n
    user_real_t noh[DIM];
    user_real_t moh[DIM];
    user_real_t nmu[DIM];
    user_real_t mmu[DIM];
    user_real_t mmuprime;
    user_real_t nmuprime;
    user_real_t dr[DIM];                          // the min image vector between two atoms
    user_real_t r;                                // the distance between two atoms 
    const user_real_t bohr_nm    = 18.8973;       // convert from bohr to nanometer
    const user_real_t cm_hartree = 2.1947463E5;   // convert from cm-1 to hartree
    user_real_t En, Em;                           // the electric field projection
    user_real_t xn, xm, pn, pm;                   // the x and p from the map
    user_real_t wn, wm;                           // the energies

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
                // Note that this is a flattened 2d array -- subtract high frequency energies to get rid of highly oscillatory parts of the F matrix
                kappa[chromn*nchrom + chromm]   = wm - avef;
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
void get_spectral_density( user_real_t *w, user_real_t *MUX, user_real_t *MUY, user_real_t *MUZ, user_real_t *omega, user_real_t *Sw, 
                           int nomega, int nchrom, user_real_t t1, user_real_t avef ){

    int istart, istride, i, chromn;
    user_real_t wi, dw, MU2, gamma;
    
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
            dw      = wi - (w[chromn] + avef) ; // also adjust for avef subtracted from kappa

            // add a lorentzian lineshape to the spectral density
            Sw[i] += MU2 * gamma / ( dw*dw + gamma*gamma )/PI;
        }
    }
}

/**********************************************************
   
        HELPER FUNCTIONS FOR GPU CALCULATIONS
            CALLABLE FROM CPU AND GPU

 **********************************************************/



// The minimage image of a scalar
user_real_t minImage( user_real_t dx, user_real_t boxl )
{
    return dx - boxl*round(dx/boxl);
}



// The magnitude of a 3 dimensional vector
user_real_t mag3( user_real_t dx[3] )
{
    return sqrt( dot3( dx, dx ) );
}



// The dot product of a 3 dimensional vector
user_real_t dot3( user_real_t x[3], user_real_t y[3] )
{
    return  x[0]*y[0] + x[1]*y[1] + x[2]*y[2];
}



// cast the matrix from float to complex -- this may not be the best way to do this, but it is quick to implement
__global__
void cast_to_complex_GPU ( user_real_t *d_d, user_complex_t *z_d, magma_int_t n )
{
    int istart, istride, i;
    
    // split up each desired frequency to separate thread on GPU
    istart  =   blockIdx.x * blockDim.x + threadIdx.x;
    istride =   blockDim.x * gridDim.x;

    // convert from float to complex
    for ( i = istart; i < n; i += istride )
    {
        z_d[i] = MAGMA_MAKE( d_d[i], 0.0 ); 
    }
}

// parse input file to setup calculation
void ir_init( char *argv[], char gmxf[], char outf[], char model[], int *ifintmeth, user_real_t *dt, int *ntcfpoints, 
              int *nsamples, int *sampleEvery, user_real_t *t1, user_real_t *avef, int *omegaStart, int *omegaStop, 
              int *omegaStep, int *natom_mol, int *nchrom_mol, int *nzeros, user_real_t *beginTime, int *ispecd,
              user_real_t *max_int_steps)
{
    char                para[MAX_STR_LEN];
    char                value[MAX_STR_LEN];

    FILE *inpf = fopen(argv[1],"r");
    if ( inpf == NULL )
    {
        printf("ERROR: Could not open %s. The first argument should contain  a  vaild\nfile name that points to a file containing the simulation parameters.\n", argv[1]);
        exit(EXIT_FAILURE);
    }
    else
        printf(">>> Reading parameters from input file %s\n", argv[1]);

    // Parse input file
    while (fscanf( inpf, "%s%s%*[^\n]", para, value ) != EOF)
    {
        if ( strcmp(para,"xtcf") == 0 ) 
        {
            sscanf( value, "%s", gmxf );
            printf("\tSetting xtc file %s\n", gmxf );
        }
        else if ( strcmp(para,"outf") == 0 )
        {
            sscanf( value, "%s", outf );
            printf("\tSetting default file name to %s\n", outf);
        }
        else if ( strcmp(para,"model") == 0 )
        {
            sscanf( value, "%s", model );
            printf("\tSetting model to %s\n", model );
            if ( strcmp( model, "tip4p2005") == 0 || strcmp( model, "e3b3") == 0 )
            {
                printf("\tThe OM distance will be adjusted to that of TIP4P for the efield calculation\n");
            }
        }
        else if ( strcmp(para,"fintmeth") == 0 )
        {
            sscanf( value, "%d", (int *) ifintmeth );
            if ( *ifintmeth < 0 || *ifintmeth > 1 ) *ifintmeth = 0;
            printf("\tSetting F integration method to %d\n", (int ) *ifintmeth);
        }
        else if ( strcmp(para,"ntcfpoints") == 0 )
        {
            sscanf( value, "%d", (int *) ntcfpoints );
            printf("\tSetting the number of tcf points to %d\n", (int) *ntcfpoints);
        }
        else if ( strcmp(para,"nsamples") == 0 )
        {
            sscanf( value, "%d", (int *) nsamples);
            printf("\tSetting nsamples to %d\n", (int) *nsamples); 
        }
        else if ( strcmp(para,"sampleEvery") == 0 )
        {
            sscanf( value, "%d", (int *) sampleEvery );
            printf("\tSetting sampleEvery to %d (ps)\n", (int) *sampleEvery);
        }
        else if ( strcmp(para,"omegaStart") == 0 )
        {
            sscanf( value, "%d", (int *) omegaStart );
            printf("\tSetting omegaStart to %d\n", (int) *omegaStart);
        }
        else if ( strcmp(para,"omegaStop") == 0 )
        {
            sscanf( value, "%d", (int *) omegaStop );
            printf("\tSetting omegaStop to %d\n", (int) *omegaStop);
        }
        else if ( strcmp(para,"omegaStep") == 0 )
        {
            sscanf( value, "%d", (int *) omegaStep );
            printf("\tSetting omegaStep to %d\n", (int) *omegaStep);
        }
        else if ( strcmp(para,"natom_mol") == 0 )
        {
            sscanf( value, "%d", (int *) natom_mol );
            printf("\tSetting natom_mol to %d\n", (int) *natom_mol);
        }
        else if ( strcmp(para,"nchrom_mol") == 0 )
        {
            sscanf( value, "%d", (int *) nchrom_mol );
            printf("\tSetting nchrom_mol to %d\n", (int) *nchrom_mol);
        }
        else if ( strcmp(para,"nzeros") == 0 )
        {
            sscanf( value, "%d", (int *) nzeros );
            printf("\tSetting nzeros to %d\n", (int) *nzeros);
        }
        else if ( strcmp(para,"specd") == 0 )
        {
            sscanf( value, "%d", (int *) ispecd);
            if ( ispecd == 0 )
            {
                printf("\tWill calculate the spectral density\n");
            }
            else
            {
                printf("\tWill not calculate the spectral density\n");
            }
        }
#ifdef USE_DOUBLES
        else if ( strcmp(para,"dt") == 0 )
        {
            sscanf( value, "%lf", dt );
            printf("\tSettting dt to %lf\n", *dt);
        }
        else if ( strcmp(para,"t1") == 0 )
        {
            sscanf( value, "%lf", t1 );
            printf("\tSetting t1 to %lf (ps)\n", *t1);
        }
        else if ( strcmp(para,"avef") == 0 )
        {
            sscanf( value, "%lf", avef );
            printf("\tSetting avef to %lf\n", *avef);
        }
        else if ( strcmp(para,"beginTime") == 0 )
        {
            sscanf( value, "%lf", beginTime );
            printf("\tSetting equilibration time to %lf (ps)\n", *beginTime );
        }
        else if ( strcmp(para,"max_int_steps") == 0 )
        {
            sscanf( value, "%lf", max_int_steps);
            printf("\tSetting max_int_steps to %lf\n", *max_int_steps );
        }
#else
        else if ( strcmp(para,"dt") == 0 )
        {
            sscanf( value, "%f", dt );
            printf("\tSettting dt to %f\n", *dt);
        }
        else if ( strcmp(para,"t1") == 0 )
        {
            sscanf( value, "%f", t1 );
            printf("\tSetting t1 to %f (ps)\n", *t1);
        }
        else if ( strcmp(para,"avef") == 0 )
        {
            sscanf( value, "%f", avef );
            printf("\tSetting avef to %f\n", *avef);
        }
        else if ( strcmp(para,"beginTime") == 0 )
        {
            sscanf( value, "%f", beginTime );
            printf("\tSetting equilibration time to %f (ps)\n", *beginTime );
        }
        else if ( strcmp(para,"max_int_steps") == 0 )
        {
            sscanf( value, "%f", max_int_steps);
            printf("\tSetting max_int_steps to %f\n", *max_int_steps );
        }
#endif
        else
        {
            printf("WARNING: Parameter %s in input file %s not recognized, ignoring.\n", para, argv[1]);
        }
    }

    fclose(inpf);
    printf(">>> Done reading input file and setting parameters\n");

}


// Progress bar to keep updated on tcf
void printProgress( int currentStep, int totalSteps )
{
    user_real_t percentage = (user_real_t) currentStep / (user_real_t) totalSteps;
    int lpad = (int) (percentage*PWID);
    int rpad = PWID - lpad;
    printf("\r [%.*s%*s]%3d%%", lpad, PSTR, rpad, "",(int) (percentage*100));
    fflush (stdout);
}
