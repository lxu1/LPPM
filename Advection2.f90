module AdvectionModule
!******************************************************************************
!	Peter A. Bosler
!	Department of Mathematics
!	University of Michigan
!	pbosler@umich.edu
!
!******************************************************************************
!
!	Defines the RK4 data structure used by SphereMesh for advection problems.
!
!	Bosler, P.A., "Particle Methods for Geophysical Flow on the Sphere," PhD Thesis; the University of Michigan, 2013.
!
!----------------
! USAGE :  This module provides methods for integrating the advection equation on the sphere.
!----------------
use NumberKindsModule
use LoggerModule
use SphereGeomModule
use ParticlesModule
use EdgesModule
use PanelsModule
use SphereMeshModule

implicit none

include 'mpif.h'

private
public AdvRK4Data
public New, Delete
public ZeroRK4
public AdvectionRK4
public LauritzenEtAlNonDivergentWind, LauritzenEtAlDivergentWind
public TestCase1Velocity, SetAlpha

!
!----------------
! Types and module constants
!----------------
!

real(kreal), save :: alpha = 0.0_kreal ! angle of inclination relative to z-axis

type AdvRK4Data
	! MPI load balancing indices
	integer(kint), pointer :: particlesIndexStart(:) => null(), &
							  particlesIndexEnd(:) =>null(), &
							  particlesMessageSize(:) => null(), &
							  activePanelsIndexStart(:) => null(), &
							  activePanelsIndexEnd(:) => null(), &
							  activePanelsMessageSize(:) => null(), &
							  passivePanelsIndexStart(:) => null() ,&
							  passivePanelsIndexEnd(:) => null(), &
							  passivePanelsMessageSize(:) => null()

	logical(klog) :: rk4isReady, &
				     mpiIsReady
	! parameters
	real(kreal) :: smooth

	! mesh variables
	type(Panels), pointer :: activePanels => null(),&
							 passivePanels => null()
	integer(kint), pointer :: activeMap(:) => null(), &
							  passiveMap(:) => null()

	! Runge-Kutta variables
	real(kreal), pointer :: particlesInput(:,:) => null(), &
							particlesStage1(:,:) => null(), &
							particlesStage2(:,:) => null(), &
							particlesStage3(:,:) => null(), &
							particlesStage4(:,:) => null(), &
							newParticlesX(:,:) => null(), &
							activePanelsInput(:,:) => null(), &
							activePanelsStage1(:,:) => null() , &
							activePanelsStage2(:,:) => null() , &
							activePanelsStage3(:,:) => null() , &
							activePanelsStage4(:,:) => null() , &
							activeDivStage1(:) => null(), &
							activeDivStage2(:) => null(), &
							activeDivStage3(:) => null(), &
							activeDivStage4(:) => null(), &
							area(:) => null(), &
							areaStage1(:) => null(), &
							areaStage2(:) => null(), &
							areaStage3(:) => null(), &
							areaStage4(:) => null(), &
							newArea(:) => null(),&
							newActivePanelsX(:,:) => null() , &
							passivePanelsInput(:,:) => null(), &
							passivePanelsStage1(:,:) => null(), &
							passivePanelsStage2(:,:) => null(), &
							passivePanelsStage3(:,:) => null(), &
							passivePanelsStage4(:,:) => null(), &
							newPassivePanelsX(:,:) => null()

end type

!
!----------------
! Logging
!----------------
!
logical(klog), save :: logInit = .FALSE.
type(Logger) :: log
character(len=28), save :: logKey = 'Advection'
integer(kint), parameter :: logLevel = TRACE_LOGGING_LEVEL
character(len=128) :: logstring
character(len=24) :: formatstring
!
!----------------
! Interfaces
!----------------
!
interface New
	module procedure NewPrivate
end interface

interface Delete
	module procedure DeletePrivate
end interface

interface
	function AdvectionVelocity(xyz,t)
		real(8) :: AdvectionVelocity(3)
		real(8), intent(in) :: xyz(3), t
	end function
end interface

contains
!
!----------------
! Standard methods : Constructor / Destructor
!----------------
!
subroutine NewPrivate(self,aMesh,nProcs,isDivergent)
	type(AdvRK4Data), intent(out) :: self
	type(SphereMesh), intent(in) :: aMesh
	integer(kint), intent(in) :: nProcs
	logical(klog), intent(in), optional :: isDivergent
	type(Particles), pointer :: aParticles
	type(Panels), pointer :: aPanels
	integer(kint) :: nParticles, nActive, nPassive, nTracer, panelKind, problemKind

	if ( .NOT. loginit) call InitLogger(log,procRank)
	call LogMessage(log,DEBUG_LOGGING_LEVEL,logKey,'Creating New AdvRK4Data.')

	self%rk4isReady = .FALSE.
	self%rk4isReady = .FALSE.

	aParticles => aMesh%particles
	aPanels => aMesh%panels

	nParticles = aParticles%N
	nActive = aPanels%N_Active
	nPassive = aPanels%N - nActive

	nTracer = aMesh%nTracer

	panelKind = aMesh%panelKind

	problemKind = ADVECTION_SOLVER

	!
	!	Allocate MPI variables
	!
	allocate(self%particlesIndexStart(0:nProcs-1))
	allocate(self%particlesIndexEnd(0:nProcs-1))
	allocate(self%particlesMessageSize(0:nProcs-1))
	self%particlesIndexStart = -1
	self%particlesIndexEnd = -1
	self%particlesMessageSize = -1
	allocate(self%activePanelsIndexStart(0:nProcs-1))
	allocate(self%activePanelsIndexEnd(0:nProcs-1))
	allocate(self%activePanelsMessageSize(0:nProcs-1))
	self%activePanelsIndexStart = -1
	self%activePanelsIndexEnd = -1
	self%activePanelsMessageSize = -1
	allocate(self%passivePanelsIndexStart(0:nProcs-1))
	allocate(self%passivePanelsIndexEnd(0:nProcs-1))
	allocate(self%passivePanelsMessageSize(0:nProcs-1))
	self%passivePanelsIndexStart = -1
	self%passivePanelsIndexEnd = -1
	self%passivePanelsMessageSize = -1

	!
	!	Set physical parameters
	!
	self%smooth = VELOCITY_SMOOTH

	!
	!	Separate active panels from passive panels
	!
	allocate(self%activePanels)
	call New(self%activePanels,nActive,panelKind,nTracer,problemKind)
	self%activePanels%N = nActive
	self%activePanels%N_Active = nActive
	allocate(self%activeMap(nActive))
	self%activeMap = 0

	allocate(self%passivePanels)
	call New(self%passivePanels,nPassive,panelKind,nTracer,problemKind)
	self%passivePanels%N = nPassive
	allocate(self%passiveMap(nPassive))
	self%passiveMap = 0

	call GatherPanels(aPanels,self%activePanels,self%activeMap,self%passivePanels,self%passiveMap)

	!
	!	Allocate RK4 variables
	!
	allocate(self%particlesInput(3,nParticles))
	allocate(self%particlesStage1(3,nParticles))
	allocate(self%particlesStage2(3,nParticles))
	allocate(self%particlesStage3(3,nParticles))
	allocate(self%particlesStage4(3,nParticles))
	allocate(self%newParticlesX(3,nParticles))

	allocate(self%activePanelsInput(3,nActive))
	allocate(self%activePanelsStage1(3,nActive))
	allocate(self%activePanelsStage2(3,nActive))
	allocate(self%activePanelsStage3(3,nActive))
	allocate(self%activePanelsStage4(3,nActive))
	allocate(self%newActivePanelsX(3,nActive))


	if ( present(isDivergent) ) then
		if ( isDivergent) then
			!allocate(self%activeDivInput(nActive))
			allocate(self%activeDivStage1(nActive))
			allocate(self%activeDivStage2(nActive))
			allocate(self%activeDivStage3(nActive))
			allocate(self%activeDivStage4(nActive))

			allocate(self%area(nActive))
			allocate(self%areaStage1(nActive))
			allocate(self%areaStage2(nActive))
			allocate(self%areaStage3(nActive))
			allocate(self%areaStage4(nActive))
			allocate(self%newArea(nActive))
		endif
	endif

	allocate(self%passivePanelsInput(3,nPassive))
	allocate(self%passivePanelsStage1(3,nPassive))
	allocate(self%passivePanelsStage2(3,nPassive))
	allocate(self%passivePanelsStage3(3,nPassive))
	allocate(self%passivePanelsStage4(3,nPassive))
	allocate(self%newPassivePanelsX(3,nPassive))

	self%rk4isReady = .TRUE.
	call ZeroRK4(self)

	call LoadBalance(self,nParticles,nActive,nPassive,nProcs)

	call LogMessage(log,DEBUG_LOGGING_LEVEL,logkey,' RK4 data ready.')
end subroutine


subroutine DeletePrivate(self)
	type(AdvRK4Data), intent(inout) :: self

	self%mpiIsReady = .FALSE.
	self%rk4isReady = .FALSE.

	deallocate(self%activeMap)
	deallocate(self%passiveMap)
	call Delete(self%activePanels)
	call Delete(self%passivePanels)
	deallocate(self%activePanels)
	deallocate(self%passivePanels)

	! MPI variables
	deallocate(self%particlesIndexStart)
	deallocate(self%particlesIndexEnd)
	deallocate(self%particlesMessageSize)
	deallocate(self%activePanelsIndexStart)
	deallocate(self%activePanelsIndexEnd)
	deallocate(self%activePanelsMessageSize)
	deallocate(self%passivePanelsIndexStart)
	deallocate(self%passivePanelsIndexEnd)
	deallocate(self%passivePanelsMessageSize)

	deallocate(self%particlesInput)
	deallocate(self%particlesStage1)
	deallocate(self%particlesStage2)
	deallocate(self%particlesStage3)
	deallocate(self%particlesStage4)
	deallocate(self%newParticlesX)

	deallocate(self%activePanelsInput)
	deallocate(self%activePanelsStage1)
	deallocate(self%activePanelsStage2)
	deallocate(self%activePanelsStage3)
	deallocate(self%activePanelsStage4)
	deallocate(self%newActivePanelsX)

	if ( associated(self%area) ) then
		deallocate(self%area)
		deallocate(self%areaStage1)
		deallocate(self%areaStage2)
		deallocate(self%areaStage3)
		deallocate(self%areaStage4)
		deallocate(self%newArea)
		deallocate(self%activeDivStage1)
		deallocate(self%activeDivStage2)
		deallocate(self%activeDivStage3)
		deallocate(self%activeDivStage4)
	endif

	deallocate(self%passivePanelsInput)
	deallocate(self%passivePanelsStage1)
	deallocate(self%passivePanelsStage2)
	deallocate(self%passivePanelsStage3)
	deallocate(self%passivePanelsStage4)
	deallocate(self%newPassivePanelsX)

end subroutine

!
!----------------
! Public member functions
!----------------
!
subroutine AdvectionRK4(self,aMesh, dt, t, procRank, nProcs, velocityFunction)
!	Non-divergent advection
!
!
	type(AdvRK4Data), intent(inout) :: self
	type(SphereMesh), intent(inout) :: aMesh
	real(kreal), intent(in) :: dt, t
	integer(kint), intent(in) :: procRank, nProcs
	procedure(AdvectionVelocity) :: velocityFunction
	type(Particles), pointer :: aParticles
	integer(kint) :: j, mpiErrCode

	call LogMessage(log,DEBUG_LOGGING_LEVEL,logKey,'Entering RK4.')

	if ( self%rk4IsReady .AND. self%mpiIsReady ) then
		call ZeroRK4(self)
	else
		call LogMessage(log,ERROR_LOGGING_LEVEL,logkey,'AdvectionRK4 ERROR : data not ready.')
		return
	endif

	if ( associated(self%area) ) then
		call LogMessage(log,WARNING_LOGGING_LEVEL,logkey,'AdvectionRK4 WARNING : nondivergent advection called.')
	endif


	aParticles => aMesh%particles

	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! 		RK Stage 1       !
	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! Set input arrays for stage 1
	self%particlesInput = aParticles%x(:,1:aParticles%N)
	self%activePanelsInput = self%activePanels%x
	self%passivePanelsInput = self%passivePanels%x

	do j=self%activePanelsIndexStart(procRank), self%activePanelsIndexEnd(procRank)
		self%activePanelsStage1(:,j) = VelocityFunction(self%activePanelsInput(:,j),t)
	enddo
	do j=self%particlesIndexStart(procRank), self%particlesIndexEnd(procRank)
		self%particlesStage1(:,j) = VelocityFunction(self%particlesInput(:,j),t)
	enddo
	do j=self%passivePanelsIndexStart(procRank), self%passivePanelsIndexEnd(procRank)
		self%passivePanelsStage1(:,j) = VelocityFunction(self%passivePanelsInput(:,j),t)
	enddo

	do j=0,nProcs-1
		call MPI_BCAST(self%particlesStage1(:,self%particlesIndexStart(j):self%particlesIndexEnd(j)), &
					   3*self%particlesMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%passivePanelsStage1(:,self%passivePanelsIndexStart(j):self%passivePanelsIndexEnd(j)), &
					   3*self%passivePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%activePanelsStage1(:,self%activePanelsIndexStart(j):self%activePanelsIndexEnd(j)), &
						3*self%activePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
						MPI_COMM_WORLD, mpiErrCode)
	enddo

! 	! STAGE 1 ONLY : Store velocity and kinetic energy
	do j=1,aParticles%N
		!aParticles%ke(j) = sum(self%particlesStage1(:,j)*self%particlesStage1(:,j))
		aParticles%u(:,j) = self%particlesStage1(:,j)
	enddo
	do j=1,self%activePanels%N
		!self%activePanels%ke(j) = sum(self%activePanelsStage1(:,j)*self%activePanelsStage1(:,j))
		self%activePanels%u(:,j) = self%activePanelsStage1(:,j)
	enddo
	!aMesh%totalKE = 0.5*sum(self%activePanels%ke*self%area)

	self%particlesStage1 = dt*self%particlesStage1
	self%passivePanelsStage1 = dt*self%passivePanelsStage1
	self%activePanelsStage1 = dt*self%activePanelsStage1

	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! 		RK Stage 2       !
	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! Set input arrays for stage 2
	self%particlesInput = aParticles%x(:,1:aParticles%N) + 0.5_kreal*self%particlesStage1
	self%activePanelsInput = self%activePanels%x + 0.5_kreal*self%activePanelsStage1
	self%passivePanelsInput = self%passivePanels%x + 0.5_kreal*self%passivePanelsStage1

	do j=self%activePanelsIndexStart(procRank), self%activePanelsIndexEnd(procRank)
		self%activePanelsStage2(:,j) = VelocityFunction(self%activePanelsInput(:,j),t + 0.5_kreal*dt)
	enddo
	do j=self%particlesIndexStart(procRank), self%particlesIndexEnd(procRank)
		self%particlesStage2(:,j) = VelocityFunction(self%particlesInput(:,j),t+ 0.5_kreal*dt)
	enddo
	do j=self%passivePanelsIndexStart(procRank), self%passivePanelsIndexEnd(procRank)
		self%passivePanelsStage2(:,j) = VelocityFunction(self%passivePanelsInput(:,j),t+ 0.5_kreal*dt)
	enddo

	do j=0,nProcs-1
		call MPI_BCAST(self%particlesStage2(:,self%particlesIndexStart(j):self%particlesIndexEnd(j)), &
					   3*self%particlesMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%passivePanelsStage2(:,self%passivePanelsIndexStart(j):self%passivePanelsIndexEnd(j)), &
					   3*self%passivePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%activePanelsStage2(:,self%activePanelsIndexStart(j):self%activePanelsIndexEnd(j)), &
						3*self%activePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
						MPI_COMM_WORLD, mpiErrCode)
	enddo

	self%particlesStage2 = dt*self%particlesStage2
	self%passivePanelsStage2 = dt*self%passivePanelsStage2
	self%activePanelsStage2 = dt*self%activePanelsStage2


	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! 		RK Stage 3       !
	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! Set input arrays for stage 3
	self%particlesInput = aParticles%x(:,1:aParticles%N) + 0.5_kreal*self%particlesStage2
	self%activePanelsInput = self%activePanels%x + 0.5_kreal*self%activePanelsStage2
	self%passivePanelsInput = self%passivePanels%x + 0.5_kreal*self%passivePanelsStage2

	do j=self%activePanelsIndexStart(procRank), self%activePanelsIndexEnd(procRank)
		self%activePanelsStage3(:,j) = VelocityFunction(self%activePanelsInput(:,j),t+ 0.5_kreal*dt)
	enddo
	do j=self%particlesIndexStart(procRank), self%particlesIndexEnd(procRank)
		self%particlesStage3(:,j) = VelocityFunction(self%particlesInput(:,j),t+ 0.5_kreal*dt)
	enddo
	do j=self%passivePanelsIndexStart(procRank), self%passivePanelsIndexEnd(procRank)
		self%passivePanelsStage3(:,j) = VelocityFunction(self%passivePanelsInput(:,j),t+ 0.5_kreal*dt)
	enddo


	do j=0,nProcs-1
		call MPI_BCAST(self%particlesStage3(:,self%particlesIndexStart(j):self%particlesIndexEnd(j)), &
					   3*self%particlesMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%passivePanelsStage3(:,self%passivePanelsIndexStart(j):self%passivePanelsIndexEnd(j)), &
					   3*self%passivePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%activePanelsStage3(:,self%activePanelsIndexStart(j):self%activePanelsIndexEnd(j)), &
						3*self%activePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
						MPI_COMM_WORLD, mpiErrCode)
		enddo

	self%particlesStage3 = dt*self%particlesStage3
	self%passivePanelsStage3 = dt*self%passivePanelsStage3
	self%activePanelsStage3 = dt*self%activePanelsStage3

	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! 		RK Stage 4       !
	!!!!!!!!!!!!!!!!!!!!!!!!!!
	! Set input arrays for stage 4
	self%particlesInput = aParticles%x(:,1:aParticles%N) + self%particlesStage3
	self%activePanelsInput = self%activePanels%x + self%activePanelsStage3
	self%passivePanelsInput = self%passivePanels%x + self%passivePanelsStage3

	do j=self%activePanelsIndexStart(procRank), self%activePanelsIndexEnd(procRank)
		self%activePanelsStage4(:,j) = VelocityFunction(self%activePanelsInput(:,j),t+dt)
	enddo
	do j=self%particlesIndexStart(procRank), self%particlesIndexEnd(procRank)
		self%particlesStage4(:,j) = VelocityFunction(self%particlesInput(:,j),t+dt)
	enddo
	do j=self%passivePanelsIndexStart(procRank), self%passivePanelsIndexEnd(procRank)
		self%passivePanelsStage4(:,j) = VelocityFunction(self%passivePanelsInput(:,j),t+dt)
	enddo

	do j=0,nProcs-1
		call MPI_BCAST(self%particlesStage4(:,self%particlesIndexStart(j):self%particlesIndexEnd(j)), &
					   3*self%particlesMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%passivePanelsStage4(:,self%passivePanelsIndexStart(j):self%passivePanelsIndexEnd(j)), &
					   3*self%passivePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
					   MPI_COMM_WORLD, mpiErrCode)
		call MPI_BCAST(self%activePanelsStage4(:,self%activePanelsIndexStart(j):self%activePanelsIndexEnd(j)), &
						3*self%activePanelsMessageSize(j), MPI_DOUBLE_PRECISION, j, &
						MPI_COMM_WORLD, mpiErrCode)
	enddo

	self%particlesStage4 = dt*self%particlesStage4
	self%passivePanelsStage4 = dt*self%passivePanelsStage4
	self%activePanelsStage4 = dt*self%activePanelsStage4

	!!!!!!!!!!!!!!!!!
	! 	RK update   !
	!!!!!!!!!!!!!!!!!

	self%newParticlesX = aParticles%x(:,1:aParticles%N) + self%particlesStage1/6.0_kreal + &
			self%particlesStage2/3.0_kreal + self%particlesStage3/3.0_kreal + self%particlesStage4/6.0_kreal
	self%newActivePanelsX = self%activePanels%x + self%activePanelsStage1/6.0_kreal + &
			self%activePanelsStage2/3.0_kreal + self%activePanelsStage3/3.0_kreal + self%activePanelsStage4/6.0_kreal
	self%newPassivePanelsX = self%passivePanels%x + self%passivePanelsStage1/6.0_kreal + &
			self%passivePanelsStage2/3.0_kreal + self%passivePanelsStage3/3.0_kreal + self%passivePanelsStage4/6.0_kreal

	aParticles%x(:,1:aParticles%N) = self%newParticlesX
	self%activePanels%x = self%newActivePanelsX
	self%passivePanels%x = self%newPassivePanelsX

	call ScatterPanels(aMesh%panels,self%activePanels,self%activeMap,self%passivePanels,self%passiveMap)
	call LogMessage(log,DEBUG_LOGGING_LEVEL,logKey,'... timestep complete.')
end subroutine


subroutine ZeroRK4(self)
	type(AdvRK4Data), intent(inout) :: self
	if ( .not. self%rk4isReady ) then
		call LogMessage(log,ERROR_LOGGING_LEVEL,'ZeroRK4 ERROR : ','memory not ready.')
		return
	endif

	call LogMessage(log,DEBUG_LOGGING_LEVEL,logKey,'Entering ZeroRK4.')

	self%particlesInput = 0.0_kreal
	self%particlesStage1 = 0.0_kreal
	self%particlesStage2 = 0.0_kreal
	self%particlesStage3 = 0.0_kreal
	self%particlesStage4 = 0.0_kreal
	self%newParticlesX = 0.0_kreal

	self%activePanelsInput = 0.0_kreal
	self%activePanelsStage1 = 0.0_kreal
	self%activePanelsStage2 = 0.0_kreal
	self%activePanelsStage3 = 0.0_kreal
	self%activePanelsStage4 = 0.0_kreal
	self%newActivePanelsX = 0.0_kreal

	self%passivePanelsInput = 0.0_kreal
	self%passivePanelsStage1 = 0.0_kreal
	self%passivePanelsStage2 = 0.0_kreal
	self%passivePanelsStage3 = 0.0_kreal
	self%passivePanelsStage4 = 0.0_kreal
	self%newPassivePanelsX = 0.0_kreal

	if ( associated(self%area) ) then
		self%area = 0.0_kreal
		self%areaStage1 = 0.0_kreal
		self%areaStage2 = 0.0_kreal
		self%areaStage3 = 0.0_kreal
		self%areaStage4 = 0.0_kreal
		self%newArea = 0.0_kreal

		!self%activeDivInput = 0.0_kreal
		self%activeDivStage1 = 0.0_kreal
		self%activeDivStage2 = 0.0_kreal
		self%activeDivStage3 = 0.0_kreal
		self%activeDivStage4 = 0.0_kreal
		!self%newActiveDiv = 0.0_kreal
	endif
end subroutine

subroutine SetAlpha(newAlpha)
	real(kreal), intent(in) :: newAlpha
	alpha = newAlpha
end subroutine

!
!----------------
! Module methods : module- or type-specific private functions
!----------------
!

subroutine LoadBalance(self,nParticles,nActive,nPassive,nProcs)
	type(AdvRK4Data), intent(inout) :: self
	integer(kint), intent(in) :: nParticles,nActive, nPassive, nProcs
	integer(kint) :: j, chunkSize

	call LogMessage(log,DEBUG_LOGGING_LEVEL,' Entering LoadBalance.')

	chunkSize = nParticles / nProcs
	do j=0,nProcs-1
		self%particlesIndexStart(j) = j*chunkSize + 1
		self%particlesIndexEnd(j) = (j+1)*chunkSize
	enddo
	self%particlesIndexEnd(nProcs-1) = nParticles
	self%particlesMessageSize = self%particlesIndexEnd - self%particlesIndexStart + 1

	chunkSize = nActive / nProcs
	do j=0,nProcs-1
		self%activePanelsIndexStart(j) = j*chunkSize + 1
		self%activePanelsIndexEnd(j) = (j+1)*chunkSize
	enddo
	self%activePanelsIndexEnd(nProcs-1) = nActive
	self%activePanelsMessageSize = self%activePanelsIndexEnd - self%activePanelsIndexStart + 1

	chunkSize = nPassive / nProcs
	do j=0,nProcs-1
		self%passivePanelsIndexStart(j) = j*chunkSize + 1
		self%passivePanelsIndexEnd(j) = (j+1)*chunkSize
	enddo
	self%passivePanelsIndexEnd(nProcs-1) = nPassive
	self%passivePanelsMessageSize = self%passivePanelsIndexEnd - self%passivePanelsIndexStart + 1

	self%mpiIsReady = .TRUE.
end subroutine

function LauritzenEtAlNonDivergentWind(xyz,t)
!  zero-divergence wind field from Lauritzen, Skamarock, Prather, & Taylor, GMD, 2012
!
	real(kreal) :: LauritzenEtAlNonDivergentWind(3)
	real(kreal), intent(in) :: xyz(3), t
	!real(kreal), parameter :: RR = 1.0_kreal, TT = 5.0_kreal
	real(kreal), parameter :: RR = EARTH_RADIUS, TT = 12.0_kreal * ONE_DAY
	real(kreal) :: u, v, lat, long, raxis
	lat = latitude(xyz)
	long = longitude(xyz)
	raxis = sqrt(xyz(1)*xyz(1) + xyz(2)*xyz(2))
	if ( raxis > ZERO_TOL) then ! Check divide by zero
		u = 10.0_kreal*RR/TT*sin(long-2.0_kreal*PI*t/TT)*sin(long-2.0_kreal*PI*t/TT)*sin(2.0_kreal*lat)*cos(PI*t/TT) + &
			2.0_kreal*PI*RR/TT*cos(lat)
		v = 10.0_kreal*RR/TT*sin(2.0_kreal*(long-2.0_kreal*PI*t/TT))*cos(lat)*cos(PI*t/TT)

		LauritzenEtAlNonDivergentWind(1) = -u*xyz(2)/raxis - v*xyz(1)*xyz(3)/raxis
		LauritzenEtAlNonDivergentWind(2) =  u*xyz(1)/raxis - v*xyz(2)*xyz(3)/raxis
		LauritzenEtAlNonDivergentWind(3) =  v*raxis
	else
		LauritzenEtAlNonDivergentWind = 0.0_kreal
	endif
end function

function LauritzenEtAlDivergentWind(xyz,t)
!  nonzero-divergence wind field from Lauritzen, Skamarock, Prather, & Taylor, GMD, 2012
!
	real(kreal), intent(in) :: xyz(3), t
	real(kreal) :: LauritzenEtAlDivergentWind(3)
	!real(kreal), parameter :: RR = 1.0_kreal, TT = 5.0_kreal
	real(kreal), parameter :: RR = EARTH_RADIUS, TT = 12.0_kreal * ONE_DAY
	real(kreal) :: u, v, lat, long, raxis
	lat = latitude(xyz)
	long = longitude(xyz)
	raxis = sqrt(xyz(1)*xyz(1) + xyz(2)*xyz(2))
	if ( raxis > ZERO_TOL) then ! Check divide by zero
		u = -5.0_kreal*RR/TT*sin((long-2.0_kreal*PI*t/TT)/2.0_kreal)*sin((long-2.0_kreal*PI*t/TT)/2.0_kreal)*sin(2.0_kreal*lat)*&
			cos(lat)*cos(lat)*cos(PI*t/TT) + 2.0_kreal*PI*RR*cos(lat)/TT
		v = 5.0_kreal*RR/(2.0_kreal*TT)*sin(long-2.0_kreal*PI*t/TT)*cos(lat)*cos(lat)*cos(lat)*cos(PI*t/TT)

		LauritzenEtAlDivergentWind(1) = -u*xyz(2)/raxis - v*xyz(1)*xyz(3)/raxis
		LauritzenEtAlDivergentWind(2) =  u*xyz(1)/raxis - v*xyz(2)*xyz(3)/raxis
		LauritzenEtAlDivergentWind(3) =  v*raxis
	else
		LauritzenEtAlDivergentWind = 0.0_kreal
	endif
end function

function TestCase1Velocity(xyz,t)
! solid-body rotation wind field from Williamson, Drake, Hack, Jakob, and Swarztrauber, JCP, 1992
	real(kreal), intent(in) :: xyz(3), t
	real(kreal) :: TestCase1Velocity(3)
	real(kreal), parameter :: u0 = 2.0_kreal*PI/(12.0_kreal*ONE_DAY)

	TestCase1Velocity(1) = -u0*xyz(2)*cos(alpha)
	TestCase1Velocity(2) =  u0*(xyz(1)*cos(alpha) - xyz(3)*sin(alpha))
	TestCase1Velocity(3) =  u0*xyz(2)*sin(alpha)
end function


subroutine InitLogger(aLog,rank)
	type(Logger), intent(inout) :: aLog
	integer(kint), intent(in) :: rank
	write(logKey,'(A,A,I0.2,A)') trim(logKey),'_',rank,' : '
	call New(aLog,logLevel)
	logInit = .TRUE.
end subroutine

end module
