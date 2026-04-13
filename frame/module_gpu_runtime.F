!WRF:FRAME_LAYER:GPU_RUNTIME
!

MODULE module_gpu_runtime

   USE module_domain, ONLY : domain
   USE module_domain_type, ONLY : fieldlist
   USE module_configure, ONLY : grid_config_rec_type
   USE module_io, ONLY : on_stream
   USE module_state_description, ONLY : PARAM_FIRST_SCALAR
   USE module_wrf_error
#if defined(DM_PARALLEL) && !defined(STUBMPI)
   USE module_dm, ONLY : wrf_get_myproc, wrf_get_nproc, wrf_get_hostid, wrf_get_dm_communicator
#endif

   IMPLICIT NONE

   PUBLIC :: wrf_gpu_rank_device
   PUBLIC :: wrf_accel_bind_device
   PUBLIC :: wrf_gpu_domain_enter
   PUBLIC :: wrf_gpu_domain_update_after_input
   PUBLIC :: wrf_gpu_domain_update_after_auxinput
   PUBLIC :: wrf_gpu_domain_update_after_bdy
   PUBLIC :: wrf_gpu_domain_prepare_history
   PUBLIC :: wrf_gpu_domain_prepare_nesting_exchange
   PUBLIC :: wrf_gpu_domain_prepare_nesting_feedback
   PUBLIC :: wrf_gpu_domain_prepare_boundary_output
   PUBLIC :: wrf_gpu_domain_prepare_full_output
   PUBLIC :: wrf_gpu_domain_exit
   PUBLIC :: wrf_gpu_smallstep_uv_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_uv_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_mu_t_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_mu_t_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_w_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_w_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_w_halo_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_p_halo_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_p_halo_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_w_halo_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_flux_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_flux_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_prep_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_init_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_init_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_init_phys_bc_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_init_body_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_early_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_finish_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_finish_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_nonhydro_tail_host_fence_begin
   PUBLIC :: wrf_gpu_smallstep_nonhydro_tail_host_fence_end
   PUBLIC :: wrf_gpu_smallstep_nonhydro_finish_host_fence_begin
   PUBLIC :: wrf_gpu_sync_real_4d_scalar_member

   INTEGER, PARAMETER :: WRF_GPU_MAX_ACTIVE_DOMAINS = 32

   LOGICAL, SAVE :: wrf_gpu_domain_slot_active(WRF_GPU_MAX_ACTIVE_DOMAINS) = .FALSE.
   INTEGER, SAVE :: wrf_gpu_domain_slot_id(WRF_GPU_MAX_ACTIVE_DOMAINS) = -1
   LOGICAL, SAVE :: wrf_gpu_domain_slot_device_data_ready(WRF_GPU_MAX_ACTIVE_DOMAINS) = .FALSE.

   INTEGER, PARAMETER :: WRF_GPU_SYNC_ENTER     = 1
   INTEGER, PARAMETER :: WRF_GPU_SYNC_TO_DEVICE = 2
   INTEGER, PARAMETER :: WRF_GPU_SYNC_TO_HOST   = 3
   INTEGER, PARAMETER :: WRF_GPU_SYNC_DELETE    = 4

CONTAINS

   SUBROUTINE wrf_gpu_rank_device( myproc, nproc, mydevice )

      INTEGER, INTENT(OUT) :: myproc, nproc, mydevice

#if defined(DM_PARALLEL) && !defined(STUBMPI)
      INTEGER :: i, hostid, loccomm, ierr, buddcounter
      INTEGER, ALLOCATABLE :: hostids(:), budds(:)
      include "mpif.h"
#endif

      myproc = 0
      nproc = 1
      mydevice = 0

#if defined(DM_PARALLEL) && !defined(STUBMPI)
      CALL wrf_get_myproc( myproc )
      CALL wrf_get_nproc( nproc )
      CALL wrf_get_hostid ( hostid )
      CALL wrf_get_dm_communicator ( loccomm )

      ALLOCATE( hostids(nproc) )
      ALLOCATE( budds(nproc) )

      CALL mpi_allgather( hostid, 1, MPI_INTEGER, hostids, 1, MPI_INTEGER, loccomm, ierr )
      IF ( ierr .NE. 0 ) THEN
         CALL wrf_error_fatal( 'module_gpu_runtime: mpi_allgather failed while assigning GPU devices' )
      END IF

      budds = -1
      buddcounter = 0
      DO i = 1, nproc
         IF ( hostid .EQ. hostids(i) ) THEN
            budds(i) = buddcounter
            buddcounter = buddcounter + 1
         END IF
      END DO

      mydevice = budds(myproc+1)

      DEALLOCATE( hostids )
      DEALLOCATE( budds )
#endif

   END SUBROUTINE wrf_gpu_rank_device

#if defined(_ACCEL) || defined(WRF_OPENACC)
   SUBROUTINE wrf_accel_bind_device( mydevice )

#ifdef _OPENMP
      USE omp_lib
#endif
#if defined(_ACCEL) || defined(WRF_OPENACC_USE_ACCEL_LIB)
      USE accel_lib
#else
      USE openacc
#endif

      INTEGER, INTENT(IN) :: mydevice
      INTEGER :: it, nt, in, devnum
#if defined(_ACCEL) || defined(WRF_OPENACC_USE_ACCEL_LIB)
      INTEGER, PARAMETER :: wrf_acc_device_kind = acc_device_nvidia
#else
      INTEGER :: wrf_acc_device_kind, nvidia_devices
#endif

#if defined(_ACCEL) || defined(WRF_OPENACC_USE_ACCEL_LIB)
      in = acc_get_num_devices( wrf_acc_device_kind )
      IF ( in .LE. 0 ) THEN
         CALL wrf_error_fatal( 'module_gpu_runtime: accelerator mode requested but no NVIDIA OpenACC devices were found' )
      END IF
#else
      nvidia_devices = acc_get_num_devices( acc_device_nvidia )
      IF ( nvidia_devices .GT. 0 ) THEN
         wrf_acc_device_kind = acc_device_nvidia
         in = nvidia_devices
      ELSE
         wrf_acc_device_kind = acc_device_default
         in = acc_get_num_devices( wrf_acc_device_kind )
      END IF
      IF ( in .LE. 0 ) THEN
         in = 1
      END IF
#endif

#ifdef _OPENMP
      !$OMP PARALLEL SHARED(mydevice,in) PRIVATE(it,nt,devnum)
      it = omp_get_thread_num()
      nt = omp_get_num_threads()
      devnum = mod( mod(mydevice*nt,in) + it, in )
# ifdef _ACCEL_PROF
      print *, "Process, Thread, Device: ",mydevice, it, devnum
# endif
      CALL acc_set_device_num( devnum, wrf_acc_device_kind )
      !$OMP END PARALLEL
#else
      it = 0
      nt = 1
      devnum = mod( mod(mydevice*nt,in) + it, in )
# ifdef _ACCEL_PROF
      print *, "Process, Thread, Device: ",mydevice, it, devnum
# endif
      CALL acc_set_device_num( devnum, wrf_acc_device_kind )
#endif

   END SUBROUTINE wrf_accel_bind_device
#endif

   INTEGER FUNCTION wrf_gpu_domain_get_slot( grid_id, create_slot )

      INTEGER, INTENT(IN) :: grid_id
      LOGICAL, INTENT(IN) :: create_slot

      INTEGER :: i, free_slot

      wrf_gpu_domain_get_slot = 0
      free_slot = 0

      DO i = 1, WRF_GPU_MAX_ACTIVE_DOMAINS
         IF ( wrf_gpu_domain_slot_active(i) ) THEN
            IF ( wrf_gpu_domain_slot_id(i) .EQ. grid_id ) THEN
               wrf_gpu_domain_get_slot = i
               RETURN
            END IF
         ELSE IF ( free_slot .EQ. 0 ) THEN
            free_slot = i
         END IF
      END DO

      IF ( .NOT. create_slot ) RETURN

      IF ( free_slot .EQ. 0 ) THEN
         CALL wrf_error_fatal( 'module_gpu_runtime: exhausted active GPU domain slots' )
      END IF

      wrf_gpu_domain_slot_active(free_slot) = .TRUE.
      wrf_gpu_domain_slot_id(free_slot) = grid_id
      wrf_gpu_domain_slot_device_data_ready(free_slot) = .FALSE.
      wrf_gpu_domain_get_slot = free_slot

   END FUNCTION wrf_gpu_domain_get_slot

   SUBROUTINE wrf_gpu_domain_enter( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .TRUE. )
      CALL wrf_gpu_domain_ensure_device_data( grid, domain_slot )

   END SUBROUTINE wrf_gpu_domain_enter

   SUBROUTINE wrf_gpu_domain_update_after_input( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      CALL wrf_gpu_domain_ensure_device_data( grid, domain_slot )
      CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_domain_update_after_input

   SUBROUTINE wrf_gpu_domain_update_after_auxinput( grid, stream_id, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: stream_id
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      CALL wrf_gpu_domain_ensure_device_data( grid, domain_slot )
      CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_TO_DEVICE, stream_id )

   END SUBROUTINE wrf_gpu_domain_update_after_auxinput

   SUBROUTINE wrf_gpu_domain_update_after_bdy( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      CALL wrf_gpu_domain_ensure_device_data( grid, domain_slot )
      CALL wrf_gpu_sync_boundary_fields( grid, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_domain_update_after_bdy

   SUBROUTINE wrf_gpu_domain_prepare_history( grid, stream_id, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: stream_id
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN
      CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_TO_HOST, stream_id )

   END SUBROUTINE wrf_gpu_domain_prepare_history

   SUBROUTINE wrf_gpu_domain_prepare_nesting_exchange( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_nesting_exchange_fields( grid, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_domain_prepare_nesting_exchange

   SUBROUTINE wrf_gpu_domain_prepare_nesting_feedback( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_nesting_feedback_fields( grid, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_domain_prepare_nesting_feedback

   SUBROUTINE wrf_gpu_domain_prepare_boundary_output( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_boundary_fields( grid, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_domain_prepare_boundary_output

   SUBROUTINE wrf_gpu_domain_prepare_full_output( grid, config_flags )

      TYPE(domain), INTENT(INOUT) :: grid
      TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_domain_prepare_full_output

   SUBROUTINE wrf_gpu_domain_exit( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN

      IF ( wrf_gpu_domain_slot_device_data_ready(domain_slot) ) THEN
         CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_boundary_fields( grid, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_DELETE )
         CALL wrf_gpu_sync_boundary_fields( grid, WRF_GPU_SYNC_DELETE )
         wrf_gpu_domain_slot_device_data_ready(domain_slot) = .FALSE.
      END IF

      wrf_gpu_domain_slot_active(domain_slot) = .FALSE.
      wrf_gpu_domain_slot_id(domain_slot) = -1

   END SUBROUTINE wrf_gpu_domain_exit

   SUBROUTINE wrf_gpu_domain_ensure_device_data( grid, domain_slot )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: domain_slot

      IF ( wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN
      CALL wrf_gpu_sync_domain_fields( grid, WRF_GPU_SYNC_ENTER )
      CALL wrf_gpu_sync_boundary_fields( grid, WRF_GPU_SYNC_ENTER )
      wrf_gpu_domain_slot_device_data_ready(domain_slot) = .TRUE.

   END SUBROUTINE wrf_gpu_domain_ensure_device_data

   SUBROUTINE wrf_gpu_smallstep_uv_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%u_2,     WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_2,     WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%ru_tend, WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%rv_tend, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_smallstep_uv_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_uv_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%u_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_2, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_uv_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_mu_t_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%t_2,  WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_smallstep_mu_t_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_mu_t_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%t_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muts, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_mu_t_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_w_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,  WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_smallstep_w_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_w_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_w_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_w_halo_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,  WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_2d_ref( grid%mudf, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_smallstep_w_halo_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_p_halo_host_fence_begin( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: i, j
      INTEGER :: halo_width
      INTEGER :: i_end, j_end

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%ph_2, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%al,   ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%p,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_2, ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mudf, ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%al,   WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%p,    WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref( grid%mudf, WRF_GPU_SYNC_TO_HOST )
      END IF

      i_end = UBOUND( grid%mu_2, 1 )
      j_end = UBOUND( grid%mu_2, 2 )

      DO j = LBOUND( grid%mu_2, 2 ), j_end
      DO i = LBOUND( grid%mu_2, 1 ), i_end
         grid%muts(i,j) = grid%mut(i,j) + grid%mu_2(i,j)
      END DO
      END DO

   END SUBROUTINE wrf_gpu_smallstep_p_halo_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_p_halo_host_fence_end( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: halo_width

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%ph_2, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%al,   ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%p,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_2, ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mudf, ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%al,   WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%p,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mudf, WRF_GPU_SYNC_TO_DEVICE )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_p_halo_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_w_halo_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%al,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%p,     WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muts,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mudf,  WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_w_halo_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_flux_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%ru_m, WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%rv_m, WRF_GPU_SYNC_TO_HOST )
      CALL wrf_gpu_sync_real_3d_ref( grid%ww_m, WRF_GPU_SYNC_TO_HOST )

   END SUBROUTINE wrf_gpu_smallstep_flux_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_flux_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%ru_m, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%rv_m, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ww_m, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_flux_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_prep_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%u_1,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%u_2,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_1,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_2,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%w_1,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%t_1,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%t_2,    WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_1,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%u_save, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_save, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%t_save, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_1,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muus,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muvs,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muts,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mudf,   WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_prep_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_init_host_fence_begin( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: halo_width

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%ph_2,   ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%al,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%p,      ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_1,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%u_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%v_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_1,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_2,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mudf,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%php,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%alt,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%pb,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_HOST )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2,    WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%al,      WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%p,       WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_1,     WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_save,  WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%u_save,  WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%v_save,  WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_1,    WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2,    WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_2d_ref( grid%mudf,    WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%php,     WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%alt,     WRF_GPU_SYNC_TO_HOST )
         CALL wrf_gpu_sync_real_3d_ref( grid%pb,      WRF_GPU_SYNC_TO_HOST )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_init_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_init_host_fence_end( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: halo_width

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%ph_2,   ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%al,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%p,      ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_1,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%u_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%v_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_1,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_2,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mudf,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%php,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%alt,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%pb,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%al,      WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%p,       WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_1,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%u_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%v_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_1,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mudf,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%php,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%alt,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%pb,      WRF_GPU_SYNC_TO_DEVICE )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_init_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_init_phys_bc_host_fence_end( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: halo_width

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%ph_2,   ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%al,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%p,      ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_1,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%t_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_1,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mu_2,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref_region( grid%mudf,   ips-halo_width, ipe+halo_width, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%al,      WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%p,       WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_1,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_1,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2,    WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mudf,    WRF_GPU_SYNC_TO_DEVICE )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_init_phys_bc_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_init_body_host_fence_end( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad
      INTEGER :: domain_slot
      INTEGER :: halo_width

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( PRESENT(ips) .AND. PRESENT(ipe) .AND. PRESENT(jps) .AND. PRESENT(jpe) .AND. &
           PRESENT(kps) .AND. PRESENT(kpe) ) THEN
         halo_width = 1
         IF ( PRESENT(halo_pad) ) halo_width = MAX( 1, halo_pad )

         CALL wrf_gpu_sync_real_3d_ref_region( grid%u_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%v_save, ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%php,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%alt,    ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref_region( grid%pb,     ips-halo_width, ipe+halo_width, kps, kpe, jps-halo_width, jpe+halo_width, WRF_GPU_SYNC_TO_DEVICE )
      ELSE
         CALL wrf_gpu_sync_real_3d_ref( grid%u_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%v_save,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%php,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%alt,     WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%pb,      WRF_GPU_SYNC_TO_DEVICE )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_init_body_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_early_host_fence_end( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%u_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%v_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%w_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ww,   WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%t_2,  WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muts, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ru_m, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%rv_m, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_3d_ref( grid%ww_m, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_early_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_nonhydro_tail_host_fence_begin( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad

      CALL wrf_gpu_smallstep_p_halo_host_fence_begin( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

   END SUBROUTINE wrf_gpu_smallstep_nonhydro_tail_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_nonhydro_tail_host_fence_end( grid, device_phys_bc_tail, &
                                                              ips, ipe, jps, jpe, kps, kpe, halo_pad )

      TYPE(domain), INTENT(INOUT) :: grid
      LOGICAL, INTENT(IN) :: device_phys_bc_tail
      INTEGER, INTENT(IN), OPTIONAL :: ips, ipe, jps, jpe, kps, kpe, halo_pad

      IF ( .NOT. device_phys_bc_tail ) RETURN

      CALL wrf_gpu_smallstep_p_halo_host_fence_end( grid, ips, ipe, jps, jpe, kps, kpe, halo_pad )

   END SUBROUTINE wrf_gpu_smallstep_nonhydro_tail_host_fence_end

   SUBROUTINE wrf_gpu_smallstep_nonhydro_finish_host_fence_begin( grid, device_phys_bc_tail )

      TYPE(domain), INTENT(INOUT) :: grid
      LOGICAL, INTENT(IN) :: device_phys_bc_tail

      IF ( device_phys_bc_tail ) RETURN

      CALL wrf_gpu_smallstep_finish_host_fence_begin( grid )

   END SUBROUTINE wrf_gpu_smallstep_nonhydro_finish_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_finish_host_fence_begin( grid )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
      CALL wrf_gpu_sync_real_2d_ref( grid%muts, WRF_GPU_SYNC_TO_DEVICE )

   END SUBROUTINE wrf_gpu_smallstep_finish_host_fence_begin

   SUBROUTINE wrf_gpu_smallstep_finish_host_fence_end( grid, sync_fluxes )

      TYPE(domain), INTENT(INOUT) :: grid
      LOGICAL, INTENT(IN) :: sync_fluxes
      INTEGER :: domain_slot

      domain_slot = wrf_gpu_domain_get_slot( grid%id, .FALSE. )
      IF ( domain_slot .LE. 0 ) RETURN
      IF ( .NOT. wrf_gpu_domain_slot_device_data_ready(domain_slot) ) RETURN

      IF ( sync_fluxes ) THEN
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%muts, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%u_2,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%v_2,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%w_2,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%t_2,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%ww,   WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%ph_2, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%mut,  WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%ru_m, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%rv_m, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_3d_ref( grid%ww_m, WRF_GPU_SYNC_TO_DEVICE )
      ELSE
         CALL wrf_gpu_sync_real_2d_ref( grid%mu_2, WRF_GPU_SYNC_TO_DEVICE )
         CALL wrf_gpu_sync_real_2d_ref( grid%muts, WRF_GPU_SYNC_TO_DEVICE )
      END IF

   END SUBROUTINE wrf_gpu_smallstep_finish_host_fence_end

   SUBROUTINE wrf_gpu_sync_domain_fields( grid, sync_mode, stream_id )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: sync_mode
      INTEGER, INTENT(IN), OPTIONAL :: stream_id

      TYPE(fieldlist), POINTER :: p

      p => grid%head_statevars%next
      DO WHILE ( ASSOCIATED(p) )
         IF ( wrf_gpu_field_is_resident( p ) ) THEN
            IF ( PRESENT(stream_id) ) THEN
               IF ( ( sync_mode .EQ. WRF_GPU_SYNC_TO_HOST .OR.                  &
                      sync_mode .EQ. WRF_GPU_SYNC_TO_DEVICE ) .AND.             &
                    p%scalar_array .AND. p%Ndim .EQ. 4 .AND.                    &
                    ( p%Type .EQ. 'r' .OR. p%Type .EQ. 'R' ) ) THEN
                  CALL wrf_gpu_sync_real_4d_scalar_stream_members( p, grid%id, stream_id, sync_mode )
                  p => p%next
                  CYCLE
               END IF
               IF ( .NOT. wrf_gpu_field_on_stream( p, grid%id, stream_id ) ) THEN
                  p => p%next
                  CYCLE
               END IF
            END IF
            CALL wrf_gpu_sync_field( p, sync_mode )
         END IF
         p => p%next
      END DO

   END SUBROUTINE wrf_gpu_sync_domain_fields

   SUBROUTINE wrf_gpu_sync_nesting_exchange_fields( grid, sync_mode )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: sync_mode

      TYPE(fieldlist), POINTER :: p
      CHARACTER(LEN=80) :: varname

      p => grid%head_statevars%next
      DO WHILE ( ASSOCIATED(p) )
         IF ( wrf_gpu_field_is_resident( p ) ) THEN
            varname = TRIM( p%VarName )
            IF ( wrf_gpu_field_in_nesting_exchange_set( varname ) ) THEN
               CALL wrf_gpu_sync_field( p, sync_mode )
            END IF
         END IF
         p => p%next
      END DO

   END SUBROUTINE wrf_gpu_sync_nesting_exchange_fields

   SUBROUTINE wrf_gpu_sync_nesting_feedback_fields( grid, sync_mode )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: sync_mode

      TYPE(fieldlist), POINTER :: p
      CHARACTER(LEN=80) :: varname

      p => grid%head_statevars%next
      DO WHILE ( ASSOCIATED(p) )
         IF ( wrf_gpu_field_is_resident( p ) ) THEN
            varname = TRIM( p%VarName )
            IF ( wrf_gpu_field_in_nesting_feedback_set( varname ) ) THEN
               CALL wrf_gpu_sync_field( p, sync_mode )
            END IF
         END IF
         p => p%next
      END DO

   END SUBROUTINE wrf_gpu_sync_nesting_feedback_fields

   SUBROUTINE wrf_gpu_sync_real_4d_scalar_stream_members( p, grid_id, stream_id, sync_mode )

      TYPE(fieldlist), POINTER, INTENT(INOUT) :: p
      INTEGER, INTENT(IN) :: grid_id, stream_id, sync_mode

      INTEGER :: itrace, itrace_lo, itrace_hi

      IF ( .NOT. ASSOCIATED(p%rfield_4d) ) RETURN
      IF ( .NOT. ASSOCIATED(p%num_table) ) RETURN
      IF ( .NOT. ASSOCIATED(p%streams_table) ) RETURN

      IF ( grid_id .LT. LBOUND(p%num_table,1) .OR. grid_id .GT. UBOUND(p%num_table,1) ) RETURN
      IF ( grid_id .LT. LBOUND(p%streams_table,1) .OR. grid_id .GT. UBOUND(p%streams_table,1) ) RETURN

      itrace_lo = MAX( PARAM_FIRST_SCALAR, LBOUND(p%rfield_4d,4), LBOUND(p%streams_table,2) )
      itrace_hi = MIN( p%num_table(grid_id), UBOUND(p%rfield_4d,4), UBOUND(p%streams_table,2) )

      IF ( itrace_hi .LT. itrace_lo ) RETURN

      DO itrace = itrace_lo, itrace_hi
         IF ( on_stream( p%streams_table(grid_id,itrace)%stream, stream_id ) ) THEN
            CALL wrf_gpu_sync_real_4d_scalar_member( p%rfield_4d, itrace, sync_mode )
         END IF
      END DO

   END SUBROUTINE wrf_gpu_sync_real_4d_scalar_stream_members

   SUBROUTINE wrf_gpu_sync_real_4d_scalar_member( field, itrace, sync_mode )

      REAL, DIMENSION(:,:,:,:), INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: itrace, sync_mode

      IF ( itrace .LT. LBOUND(field,4) .OR. itrace .GT. UBOUND(field,4) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field(:,:,:,itrace))
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field(:,:,:,itrace))
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_4d_scalar_member

   SUBROUTINE wrf_gpu_sync_boundary_fields( grid, sync_mode )

      TYPE(domain), INTENT(INOUT) :: grid
      INTEGER, INTENT(IN) :: sync_mode

      CALL wrf_gpu_sync_real_3d_alloc( grid%u_bxs,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_bxe,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_bys,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_bye,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_btxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_btxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_btys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%u_btye,  sync_mode )

      CALL wrf_gpu_sync_real_3d_alloc( grid%v_bxs,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_bxe,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_bys,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_bye,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_btxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_btxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_btys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%v_btye,  sync_mode )

      CALL wrf_gpu_sync_real_3d_alloc( grid%w_bxs,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_bxe,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_bys,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_bye,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_btxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_btxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_btys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%w_btye,  sync_mode )

      CALL wrf_gpu_sync_real_3d_alloc( grid%t_bxs,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_bxe,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_bys,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_bye,   sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_btxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_btxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_btys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%t_btye,  sync_mode )

      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_bxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_bxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_bys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_bye,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_btxs, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_btxe, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_btys, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%ph_btye, sync_mode )

      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_bxs,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_bxe,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_bys,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_bye,  sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_btxs, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_btxe, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_btys, sync_mode )
      CALL wrf_gpu_sync_real_3d_alloc( grid%mu_btye, sync_mode )

      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_bxs,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_bxe,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_bys,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_bye,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_btxs, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_btxe, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_btys, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%moist_btye, sync_mode )

      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_bxs,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_bxe,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_bys,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_bye,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_btxs, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_btxe, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_btys, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%scalar_btye, sync_mode )

      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_bxs,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_bxe,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_bys,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_bye,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_btxs, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_btxe, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_btys, sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%tracer_btye, sync_mode )

#if ( WRF_CHEM == 1 )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_bxs,   sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_bxe,   sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_bys,   sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_bye,   sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_btxs,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_btxe,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_btys,  sync_mode )
      CALL wrf_gpu_sync_real_4d_alloc( grid%chem_btye,  sync_mode )
#endif

   END SUBROUTINE wrf_gpu_sync_boundary_fields

   LOGICAL FUNCTION wrf_gpu_field_is_resident( p )

      TYPE(fieldlist), POINTER, INTENT(IN) :: p
      CHARACTER(LEN=80) :: varname

      wrf_gpu_field_is_resident = .FALSE.

      IF ( .NOT. ASSOCIATED(p) ) RETURN
      varname = TRIM( p%VarName )

      SELECT CASE ( p%Type )
      CASE ( 'r', 'R' )
         wrf_gpu_field_is_resident = wrf_gpu_field_in_dyn_set( varname )         .OR. &
                                     wrf_gpu_field_in_surface_pbl_set( varname ) .OR. &
                                     wrf_gpu_field_in_microphysics_set( varname )
      CASE ( 'i', 'I' )
         wrf_gpu_field_is_resident = wrf_gpu_field_in_surface_pbl_integer_set( varname )
      END SELECT

   END FUNCTION wrf_gpu_field_is_resident

   LOGICAL FUNCTION wrf_gpu_field_in_dyn_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_dyn_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'u_1', 'u_2', 'v_1', 'v_2', 'w_1', 'w_2', 'ww', 'ww_m',        &
             'ru', 'rv', 'rw', 'p', 'al', 'alt', 'alb', 'pb', 'php', 'phb',&
             'ph_1', 'ph_2', 't_1', 't_2', 't_init', 't_phy', 'ht', 'rho',  &
             'p8w', 'p_hyd', 'p_hyd_w', 'dz8w', 'o3rad', 'cldfra',          &
             'rthraten', 'rthratenlw', 'rthratensw',                         &
             'rthratenlwc', 'rthratenswc',                                   &
             'mu_1', 'mu_2', 'mub', 'mut', 'muu', 'muus', 'muv', 'muvs',    &
             'muts', 'mudf', 'msft', 'msfu', 'msfv',                         &
             'ru_m', 'ru_tend', 'rv_m', 'rv_tend',                           &
             'rw_tend', 'rw_tendf', 'ph_tend', 'ph_tendf',                  &
             't_tend', 't_tendf', 'mu_tend', 'mu_tendf',                    &
             'u_save', 'v_save', 'w_save', 't_save', 'ph_save', 'mu_save',  &
             'h_diabatic', 'rthften', 'ww1', 'wwe', 'wwi', 'muave',         &
             't_2save', 'alpha', 'a', 'gamma', 'c2a', 'cqu', 'cqv', 'cqw', &
             'pm1', 'fnm', 'fnp', 'rdn', 'rdnw', 'dnw', 'znu', 'znw',       &
             'fcx', 'gcx',                                                   &
             'c1h', 'c2h', 'c3h', 'c4h', 'c1f', 'c2f', 'c3f', 'c4f',        &
             'msfux', 'msfuy', 'msfvx', 'msfvx_inv', 'msfvy', 'msftx',       &
             'msfty', 'cf1', 'cf2', 'cf3', 'cfn', 'cfn1', 'clat', 'f', 'e', &
             'sina', 'cosa', 'khdif', 'kvdif', 'xkmh', 'xkhh', 'smdiv',     &
             'emdiv', 'epssm', 'dampcoef', 'u_base', 'v_base', 't_base',    &
             'qv_base', 'z_base', 'u_frame', 'v_frame' )
         wrf_gpu_field_in_dyn_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_dyn_set

   LOGICAL FUNCTION wrf_gpu_field_in_surface_pbl_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_surface_pbl_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'psfc', 'psfc_old', 'q2', 't2', 'th2', 'u10', 'v10',           &
             'qsfc', 'tsk', 'tmn', 'xland', 'xice', 'snow', 'snowh',        &
             'snowc', 'snownc', 'snowncv', 'canwat', 'smois', 'sh2o',       &
             'smcrel', 'smstav', 'smstot', 'sfcrunoff', 'udrunoff',         &
             'vegfra', 'lai', 'tslb', 'capg', 'thc', 'gsw', 'glw',          &
             'swdown', 'swddir', 'swddif',                                  &
             'albedo', 'albbck', 'emiss', 'embck',                          &
             'znt', 'z0', 'qz0', 'ck', 'cka', 'cd', 'cda', 'ust', 'ustm',  &
             'flhc', 'flqc', 'flx4', 'fvb', 'fbur', 'fgsn',                 &
             'fm', 'fh', 'wspd', 'br', 'mavail', 'uoce', 'voce',            &
             'ctopo', 'ctopo2',                                             &
             'zol', 'mol', 'rmol', 'regime', 'pblh', 'hfx', 'qfx', 'lh',    &
             'sfcevp', 'sfcexc', 'achfx', 'aclhf', 'acgrdflx',              &
             'rainbl', 'potevp', 'snopcx',                                   &
             'acsnow', 'acsnom', 'noahres', 'exch_h', 'exch_m',             &
             'rublten', 'rvblten', 'rthblten', 'rqvblten',                   &
             'rqcblten', 'rqiblten', 'wstar_ysu', 'delta_ysu' )
         wrf_gpu_field_in_surface_pbl_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_surface_pbl_set

   LOGICAL FUNCTION wrf_gpu_field_in_surface_pbl_integer_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_surface_pbl_integer_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'kpbl', 'regime', 'stepbl', 'ivgtyp', 'isltyp' )
         wrf_gpu_field_in_surface_pbl_integer_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_surface_pbl_integer_set

   LOGICAL FUNCTION wrf_gpu_field_in_microphysics_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_microphysics_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'moist', 'moist_old', 'moist_tend',                             &
             'scalar', 'tracer', 'chem',                                     &
             'rainnc', 'rainncv', 'sr', 'cfrach', 're_cloud',               &
             're_cloud_gsfc', 're_ice', 're_ice_gsfc',                      &
             're_snow', 're_snow_gsfc' )
         wrf_gpu_field_in_microphysics_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_microphysics_set

   LOGICAL FUNCTION wrf_gpu_field_in_nesting_exchange_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_nesting_exchange_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'u_2', 'v_2', 'w_2', 'ph_2', 'phb', 't_2', 't_init',           &
             'mu_2', 'mub', 'alb', 'pb',                                     &
             'moist', 'scalar', 'tracer', 'rainnc', 'rainncv',               &
             'psfc', 'q2', 't2', 'th2', 'u10', 'v10', 'tsk',                 &
             'vegfra', 'tslb', 'smois', 'sh2o', 'smcrel', 'smstav',          &
             'xice', 'snow', 'snowh', 'canwat', 'sstsk', 'uoce', 'voce',    &
             'sfcrunoff', 'udrunoff', 'acgrdflx', 'acsnow',                  &
             'acrunoff', 'acsnom',                                           &
             'ivgtyp', 'isltyp',                                             &
             'msft', 'msfu', 'msfv', 'msftx', 'msfty',                       &
             'msfux', 'msfuy', 'msfvx', 'msfvx_inv', 'msfvy',                &
             'f', 'e', 'sina', 'cosa', 'ht',                                 &
             'o3rad', 'h_diabatic' )
         wrf_gpu_field_in_nesting_exchange_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_nesting_exchange_set

   LOGICAL FUNCTION wrf_gpu_field_in_nesting_feedback_set( varname )

      CHARACTER(LEN=*), INTENT(IN) :: varname

      wrf_gpu_field_in_nesting_feedback_set = .FALSE.

      SELECT CASE ( varname )
      CASE ( 'u_2', 'v_2', 'w_2', 'ph_2', 'phb', 't_2',                     &
             'mu_2', 'mub', 'alb', 'pb',                                     &
             'moist', 'scalar', 'tracer', 'rainnc', 'rainncv',               &
             'psfc', 'q2', 't2', 'th2', 'u10', 'v10', 'tsk',                 &
             'vegfra', 'tslb', 'smois', 'sh2o', 'smcrel', 'smstav',          &
             'xice', 'snow', 'snowh', 'canwat', 'sstsk',                     &
             'sfcrunoff', 'udrunoff', 'acgrdflx', 'acsnow',                  &
             'acrunoff', 'acsnom',                                           &
             'ivgtyp', 'isltyp',                                             &
             'msft', 'msfu', 'msfv', 'msftx', 'msfty',                       &
             'msfux', 'msfuy', 'msfvx', 'msfvx_inv', 'msfvy',                &
             'f', 'e', 'sina', 'cosa', 'ht',                                 &
             'h_diabatic' )
         wrf_gpu_field_in_nesting_feedback_set = .TRUE.
      END SELECT

   END FUNCTION wrf_gpu_field_in_nesting_feedback_set

   LOGICAL FUNCTION wrf_gpu_field_on_stream( p, grid_id, stream_id )

      TYPE(fieldlist), POINTER, INTENT(IN) :: p
      INTEGER, INTENT(IN) :: grid_id, stream_id

      INTEGER :: itrace, ntrace

      wrf_gpu_field_on_stream = .FALSE.

      IF ( .NOT. ASSOCIATED(p) ) RETURN

      IF ( p%scalar_array ) THEN
         IF ( ASSOCIATED(p%num_table) .AND. ASSOCIATED(p%streams_table) ) THEN
            IF ( grid_id .GE. LBOUND(p%num_table,1) .AND. grid_id .LE. UBOUND(p%num_table,1) ) THEN
               ntrace = p%num_table(grid_id)
               DO itrace = PARAM_FIRST_SCALAR, ntrace
                  IF ( on_stream( p%streams_table(grid_id,itrace)%stream, stream_id ) ) THEN
                     wrf_gpu_field_on_stream = .TRUE.
                     RETURN
                  END IF
               END DO
            END IF
         END IF
      ELSE
         wrf_gpu_field_on_stream = on_stream( p%streams, stream_id )
      END IF

   END FUNCTION wrf_gpu_field_on_stream

   SUBROUTINE wrf_gpu_sync_field( p, sync_mode )

      TYPE(fieldlist), POINTER, INTENT(INOUT) :: p
      INTEGER, INTENT(IN) :: sync_mode

      SELECT CASE ( p%Type )
      CASE ( 'r', 'R' )
         SELECT CASE ( p%Ndim )
         CASE ( 0 )
            CALL wrf_gpu_sync_real_0d( p%rfield_0d, sync_mode )
         CASE ( 1 )
            CALL wrf_gpu_sync_real_1d( p%rfield_1d, sync_mode )
         CASE ( 2 )
            CALL wrf_gpu_sync_real_2d( p%rfield_2d, sync_mode )
         CASE ( 3 )
            CALL wrf_gpu_sync_real_3d( p%rfield_3d, sync_mode )
         CASE ( 4 )
            CALL wrf_gpu_sync_real_4d( p%rfield_4d, sync_mode )
         END SELECT
      CASE ( 'i', 'I' )
         SELECT CASE ( p%Ndim )
         CASE ( 0 )
            CALL wrf_gpu_sync_integer_0d( p%ifield_0d, sync_mode )
         CASE ( 1 )
            CALL wrf_gpu_sync_integer_1d( p%ifield_1d, sync_mode )
         CASE ( 2 )
            CALL wrf_gpu_sync_integer_2d( p%ifield_2d, sync_mode )
         CASE ( 3 )
            CALL wrf_gpu_sync_integer_3d( p%ifield_3d, sync_mode )
         CASE ( 4 )
            CALL wrf_gpu_sync_integer_4d( p%ifield_4d, sync_mode )
         END SELECT
      END SELECT

   END SUBROUTINE wrf_gpu_sync_field

   SUBROUTINE wrf_gpu_sync_real_0d( field, sync_mode )

      REAL, POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_0d

   SUBROUTINE wrf_gpu_sync_real_1d( field, sync_mode )

      REAL, DIMENSION(:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_1d

   SUBROUTINE wrf_gpu_sync_real_3d_alloc( field, sync_mode )

      REAL, DIMENSION(:,:,:), ALLOCATABLE, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ALLOCATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_3d_alloc

   SUBROUTINE wrf_gpu_sync_real_4d_alloc( field, sync_mode )

      REAL, DIMENSION(:,:,:,:), ALLOCATABLE, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ALLOCATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_4d_alloc

   SUBROUTINE wrf_gpu_sync_real_2d_ref( field, sync_mode )

      REAL, DIMENSION(:,:), INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_2d_ref

   SUBROUTINE wrf_gpu_sync_real_2d_ref_region( field, i_lo_in, i_hi_in, j_lo_in, j_hi_in, sync_mode )

      REAL, DIMENSION(:,:), INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: i_lo_in, i_hi_in, j_lo_in, j_hi_in, sync_mode
      INTEGER :: i_lo, i_hi, j_lo, j_hi

      i_lo = MAX( LBOUND( field, 1 ), i_lo_in )
      i_hi = MIN( UBOUND( field, 1 ), i_hi_in )
      j_lo = MAX( LBOUND( field, 2 ), j_lo_in )
      j_hi = MIN( UBOUND( field, 2 ), j_hi_in )
      IF ( i_lo .GT. i_hi .OR. j_lo .GT. j_hi ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field(i_lo:i_hi,j_lo:j_hi))
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field(i_lo:i_hi,j_lo:j_hi))
      CASE DEFAULT
         CALL wrf_gpu_sync_real_2d_ref( field, sync_mode )
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_2d_ref_region

   SUBROUTINE wrf_gpu_sync_real_3d_ref( field, sync_mode )

      REAL, DIMENSION(:,:,:), INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_3d_ref

   SUBROUTINE wrf_gpu_sync_real_3d_ref_region( field, i_lo_in, i_hi_in, k_lo_in, k_hi_in, j_lo_in, j_hi_in, sync_mode )

      REAL, DIMENSION(:,:,:), INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: i_lo_in, i_hi_in, k_lo_in, k_hi_in, j_lo_in, j_hi_in, sync_mode
      INTEGER :: i_lo, i_hi, j_lo, j_hi, k_lo, k_hi

      i_lo = MAX( LBOUND( field, 1 ), i_lo_in )
      i_hi = MIN( UBOUND( field, 1 ), i_hi_in )
      k_lo = MAX( LBOUND( field, 2 ), k_lo_in )
      k_hi = MIN( UBOUND( field, 2 ), k_hi_in )
      j_lo = MAX( LBOUND( field, 3 ), j_lo_in )
      j_hi = MIN( UBOUND( field, 3 ), j_hi_in )
      IF ( i_lo .GT. i_hi .OR. k_lo .GT. k_hi .OR. j_lo .GT. j_hi ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field(i_lo:i_hi,k_lo:k_hi,j_lo:j_hi))
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field(i_lo:i_hi,k_lo:k_hi,j_lo:j_hi))
      CASE DEFAULT
         CALL wrf_gpu_sync_real_3d_ref( field, sync_mode )
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_3d_ref_region

   SUBROUTINE wrf_gpu_sync_real_2d( field, sync_mode )

      REAL, DIMENSION(:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_2d

   SUBROUTINE wrf_gpu_sync_real_3d( field, sync_mode )

      REAL, DIMENSION(:,:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_3d

   SUBROUTINE wrf_gpu_sync_real_4d( field, sync_mode )

      REAL, DIMENSION(:,:,:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_real_4d

   SUBROUTINE wrf_gpu_sync_integer_0d( field, sync_mode )

      INTEGER, POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_integer_0d

   SUBROUTINE wrf_gpu_sync_integer_1d( field, sync_mode )

      INTEGER, DIMENSION(:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_integer_1d

   SUBROUTINE wrf_gpu_sync_integer_2d( field, sync_mode )

      INTEGER, DIMENSION(:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_integer_2d

   SUBROUTINE wrf_gpu_sync_integer_3d( field, sync_mode )

      INTEGER, DIMENSION(:,:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_integer_3d

   SUBROUTINE wrf_gpu_sync_integer_4d( field, sync_mode )

      INTEGER, DIMENSION(:,:,:,:), POINTER, INTENT(INOUT) :: field
      INTEGER, INTENT(IN) :: sync_mode

      IF ( .NOT. ASSOCIATED(field) ) RETURN

      SELECT CASE ( sync_mode )
      CASE ( WRF_GPU_SYNC_ENTER )
!$acc enter data copyin(field)
      CASE ( WRF_GPU_SYNC_TO_DEVICE )
!$acc update device(field)
      CASE ( WRF_GPU_SYNC_TO_HOST )
!$acc update host(field)
      CASE ( WRF_GPU_SYNC_DELETE )
!$acc exit data delete(field)
      END SELECT

   END SUBROUTINE wrf_gpu_sync_integer_4d

END MODULE module_gpu_runtime
