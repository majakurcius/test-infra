// Code generated by mockery v1.0.0. DO NOT EDIT.

package automock

import (
	context "context"

	mock "github.com/stretchr/testify/mock"
)

// API is an autogenerated mock type for the API type
type API struct {
	mock.Mock
}

// Create provides a mock function with given fields: ctx, name, labels, minPoolSize, autoScaling
func (_m *API) Create(ctx context.Context, name string, labels map[string]string, minPoolSize int, autoScaling bool) error {
	ret := _m.Called(ctx, name, labels, minPoolSize, autoScaling)

	var r0 error
	if rf, ok := ret.Get(0).(func(context.Context, string, map[string]string, int, bool) error); ok {
		r0 = rf(ctx, name, labels, minPoolSize, autoScaling)
	} else {
		r0 = ret.Error(0)
	}

	return r0
}

// Delete provides a mock function with given fields: ctx, name
func (_m *API) Delete(ctx context.Context, name string) error {
	ret := _m.Called(ctx, name)

	var r0 error
	if rf, ok := ret.Get(0).(func(context.Context, string) error); ok {
		r0 = rf(ctx, name)
	} else {
		r0 = ret.Error(0)
	}

	return r0
}