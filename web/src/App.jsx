import { lazy, Suspense } from 'react';
import PageLoader from './components/PageLoader';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './hooks/useAuth';
import { ProtectedLayout, AuthLayout } from './components/Layout';
import Login        from './pages/auth/Login';
import Signup       from './pages/auth/Signup';
import ForgotPassword from './pages/auth/ForgotPassword';
import ResetPassword  from './pages/auth/ResetPassword';
import Invitation     from './pages/auth/Invitation';
const Dashboard = lazy(() => import('./pages/Dashboard'));
const Products = lazy(() => import('./pages/Products'));
const Materials = lazy(() => import('./pages/Materials'));
const Branches = lazy(() => import('./pages/Branches'));
const UsersPage = lazy(() => import('./pages/Users'));
const Recipes = lazy(() => import('./pages/Recipes'));
const Pricing = lazy(() => import('./pages/Pricing'));
const Settings = lazy(() => import('./pages/Settings'));
const Categories = lazy(() => import('./pages/Categories'));
const Colours = lazy(() => import('./pages/Colours'));
const ReviewQueue = lazy(() => import('./pages/ReviewQueue'));
const Suppliers = lazy(() => import('./pages/Suppliers'));
const Stock = lazy(() => import('./pages/Stock'));
const Movements = lazy(() => import('./pages/Movements'));
const StockImport = lazy(() => import('./pages/StockImport'));
const Approvals = lazy(() => import('./pages/Approvals'));
const Purchases = lazy(() => import('./pages/Purchases'));
const Production = lazy(() => import('./pages/Production'));
const ProductionLedger = lazy(() => import('./pages/ProductionLedger'));
const Costing = lazy(() => import('./pages/Costing'));
const Sales = lazy(() => import('./pages/Sales'));
const Customers = lazy(() => import('./pages/Customers'));
const SaleDocument = lazy(() => import('./pages/SaleDocument'));
const StatementDocument = lazy(() => import('./pages/StatementDocument'));
const PurchaseOrderDocument = lazy(() => import('./pages/PurchaseOrderDocument'));
const WeeklyCash = lazy(() => import('./pages/WeeklyCash'));
const Staff = lazy(() => import('./pages/Staff'));
const DailyReport = lazy(() => import('./pages/DailyReport'));
const Reports = lazy(() => import('./pages/Reports'));
const Statements = lazy(() => import('./pages/Statements'));
const Documents = lazy(() => import('./pages/Documents'));
const PrintLists = lazy(() => import('./pages/PrintLists'));
const ListDocument = lazy(() => import('./pages/ListDocument'));
const CashFlow = lazy(() => import('./pages/CashFlow'));
const PayslipDocument = lazy(() => import('./pages/PayslipDocument'));
const GoodsReceivedDocument = lazy(() => import('./pages/GoodsReceivedDocument'));
const JobCardDocument = lazy(() => import('./pages/JobCardDocument'));
const SupplierStatementDocument = lazy(() => import('./pages/SupplierStatementDocument'));

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Suspense fallback={<PageLoader />}>
        <Routes>
          {/* Auth routes (redirect to / if already signed in) */}
          <Route element={<AuthLayout />}>
            <Route path="/login"           element={<Login />} />
            <Route path="/signup"          element={<Signup />} />
            <Route path="/forgot-password" element={<ForgotPassword />} />
            <Route path="/invite"          element={<Invitation />} />
          </Route>

          {/* The recovery link signs the user in, so this page must not sit
              under AuthLayout (which redirects signed-in users away). */}
          <Route path="/reset-password" element={<ResetPassword />} />

          {/* A sale's printable documents: a tab of their own, no sidebar (signed-in check inside) */}
          <Route path="/print/sale/:id" element={<SaleDocument />} />
          <Route path="/print/statement/:id" element={<StatementDocument />} />
          <Route path="/print/payslips/:id" element={<PayslipDocument />} />
          <Route path="/print/grn/:id" element={<GoodsReceivedDocument />} />
          <Route path="/print/job-card/:batchId" element={<JobCardDocument />} />
          <Route path="/print/supplier-statement/:id" element={<SupplierStatementDocument />} />
          <Route path="/print/po/:id" element={<PurchaseOrderDocument />} />
          <Route path="/print/list/:kind" element={<ListDocument />} />

          {/* Protected routes (redirect to /login if not signed in) */}
          <Route element={<ProtectedLayout />}>
            <Route index               element={<Dashboard />} />
            <Route path="/products"    element={<Products />} />
            <Route path="/categories"  element={<Categories />} />
            <Route path="/colours"     element={<Colours />} />
            <Route path="/review"      element={<ReviewQueue />} />
            <Route path="/approvals"   element={<Approvals />} />
            <Route path="/suppliers"   element={<Suppliers />} />
            <Route path="/stock"       element={<Stock />} />
            <Route path="/movements"   element={<Movements />} />
            <Route path="/purchases"   element={<Purchases key="purchases" />} />
            <Route path="/expenses"    element={<Purchases key="expenses" section="expenses" />} />
            <Route path="/orders"      element={<Purchases key="orders" section="orders" />} />
            <Route path="/production"  element={<Production />} />
            <Route path="/production/ledger" element={<ProductionLedger />} />
            <Route path="/costing" element={<Costing />} />
            <Route path="/sales" element={<Sales />} />
            <Route path="/customers" element={<Customers />} />
            <Route path="/weekly-cash" element={<WeeklyCash />} />
            <Route path="/cash-flow" element={<CashFlow />} />
            <Route path="/staff" element={<Staff />} />
            <Route path="/daily-report" element={<DailyReport />} />
            <Route path="/reports" element={<Reports />} />
            <Route path="/statements" element={<Statements />} />
            <Route path="/documents" element={<Documents />} />
            <Route path="/print-lists" element={<PrintLists />} />
            <Route path="/stock/import" element={<StockImport />} />
            <Route path="/materials"   element={<Materials />} />
            <Route path="/branches"    element={<Branches />} />
            <Route path="/users"       element={<UsersPage />} />
            <Route path="/recipes"     element={<Recipes />} />
            <Route path="/pricing"     element={<Pricing />} />
            <Route path="/settings"    element={<Settings />} />
          </Route>

          {/* Catch-all */}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Suspense>
      </BrowserRouter>
    </AuthProvider>
  );
}
