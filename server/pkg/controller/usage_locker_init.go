package controller

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"time"

	"github.com/ente/museum/pkg/controller/lock"
	"github.com/ente/museum/pkg/repo"
	timeUtil "github.com/ente/museum/pkg/utils/time"
	log "github.com/sirupsen/logrus"
)

type LockerUsageInitializer struct {
	UsageRepo      *repo.UsageRepository
	LockController *lock.LockController
	queue          chan int64
	mu             sync.Mutex
	attemptedAt    map[int64]time.Time
	lastPrunedAt   time.Time
}

const (
	lockerUsageInitializationQueueSize = 100
	lockerUsageInitializationRetry     = time.Hour
	lockerUsageInitializationLock      = "locker_usage_initialization"
)

func NewLockerUsageInitializer(usageRepo *repo.UsageRepository, lockController *lock.LockController) *LockerUsageInitializer {
	return &LockerUsageInitializer{
		UsageRepo:      usageRepo,
		LockController: lockController,
		queue:          make(chan int64, lockerUsageInitializationQueueSize),
		attemptedAt:    make(map[int64]time.Time),
		lastPrunedAt:   time.Now(),
	}
}

func (c *LockerUsageInitializer) Enqueue(userID int64) {
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	if attemptedAt, ok := c.attemptedAt[userID]; ok && (attemptedAt.IsZero() || now.Sub(attemptedAt) < lockerUsageInitializationRetry) {
		return
	}
	select {
	case c.queue <- userID:
		c.attemptedAt[userID] = time.Time{}
	default:
	}
}

func (c *LockerUsageInitializer) Run() {
	for userID := range c.queue {
		c.initializeUser(userID)
		now := time.Now()
		c.mu.Lock()
		c.attemptedAt[userID] = now
		if now.Sub(c.lastPrunedAt) >= lockerUsageInitializationRetry {
			for id, attemptedAt := range c.attemptedAt {
				if !attemptedAt.IsZero() && now.Sub(attemptedAt) >= lockerUsageInitializationRetry {
					delete(c.attemptedAt, id)
				}
			}
			c.lastPrunedAt = now
		}
		c.mu.Unlock()
	}
}

func (c *LockerUsageInitializer) initializeUser(userID int64) {
	lockID := lockerUsageInitializationLock + ":" + strconv.FormatInt(userID, 10)
	if !c.LockController.TryLock(lockID, timeUtil.MicrosecondsAfterHours(3)) {
		return
	}
	defer c.LockController.ReleaseLock(lockID)

	initialized, err := c.UsageRepo.InitializeLockerUsage(context.Background(), userID)
	if errors.Is(err, repo.ErrLockerUsageIneligible) {
		log.WithError(err).WithField("user_id", userID).Warn("Locker usage initialization ineligible")
	} else if err != nil {
		log.WithError(err).WithField("user_id", userID).Error("Failed to initialize Locker usage")
	} else if initialized {
		log.WithField("user_id", userID).Info("Initialized Locker usage")
	}
}
